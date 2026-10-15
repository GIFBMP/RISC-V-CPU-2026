#!/usr/bin/env python3
"""Run the unmodified course simulator and compare every architectural commit.

Expected RTL lines (hex fields have no 0x requirement):
CPU_TRACE COMMIT seq=0 id=0 cycle=7 pc=00000000 insn=12345678 rd=1 value=00000001 store=0 addr=00000000 data=00000000 strb=0
CPU_TRACE ISSUE id=0 cycle=5 pc=00000000 insn=12345678
CPU_TRACE COMPLETE id=0 cycle=6 pc=00000000 insn=12345678
"""
from __future__ import annotations

import argparse
from dataclasses import asdict
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from rv32_reference import Commit, RV32

TRACE = re.compile(r"CPU_TRACE\s+(COMMIT|ISSUE|COMPLETE|DISPATCH|FLUSH|DROP_LOAD|WB_STALL|RENAME_BYPASS|MEM_RESPONSE|STORE_RETIRE)\s+(.*)")
DECIMAL = {"seq", "id", "cycle", "rd", "pdst", "store", "load_pending", "source", "write", "killed"}
PASS = re.compile(r"^PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*$")


def parse_trace(line: str) -> tuple[str, dict[str, int]] | None:
    match = TRACE.search(line)
    if not match:
        return None
    fields = {}
    for token in match[2].split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        fields[key] = int(value, 10 if key in DECIMAL else 16)
    return match[1], fields


def compare_commit(actual: dict[str, int], expected: Commit) -> str | None:
    wanted = asdict(expected)
    required = ("seq", "pc", "insn", "rd", "value", "store")
    if expected.store:
        required += ("addr", "data", "strb")
    for key in required:
        if key not in actual:
            return f"commit {expected.seq}: missing {key} in trace"
        got, want = actual[key], wanted[key]
        if key == "data":
            mask = sum(0xFF << (lane * 8) for lane in range(4) if expected.strb & (1 << lane))
            got &= mask
        if got != want:
            return (f"commit {expected.seq} pc={expected.pc:08x} insn={expected.insn:08x}: "
                    f"{key} expected={want:#x} actual={got:#x}")
    return None


def check_ooo(probe: dict, events: list[tuple[str, dict]]) -> tuple[str | None, dict]:
    def matching(kind: str, pc: int) -> list[dict]:
        return [fields for event, fields in events if event == kind and fields.get("pc") == pc]

    older_issue = matching("ISSUE", probe["older_pc"])
    younger_issue = matching("ISSUE", probe["younger_pc"])
    older_commit = matching("COMMIT", probe["older_pc"])
    younger_commit = matching("COMMIT", probe["younger_pc"])
    # Only an issue whose allocation ID later committed is evidence. A squashed
    # speculative execution at the same PC must not satisfy the requirement.
    for older in older_commit:
        for younger in younger_commit:
            oi = next((item for item in older_issue if item.get("id") == older.get("id")), None)
            yi = next((item for item in younger_issue if item.get("id") == younger.get("id")), None)
            if not oi or not yi or any("cycle" not in item or "id" not in item for item in (oi, yi, older, younger)):
                continue
            if yi["cycle"] < oi["cycle"] and older["seq"] < younger["seq"]:
                return None, {"older_issue": oi, "younger_issue": yi,
                              "older_commit": older, "younger_commit": younger}
    return (f"no genuine OoO issue: young pc={probe['younger_pc']:08x} must issue before "
            f"dependent older pc={probe['older_pc']:08x}, then commit after it"), {
                "older_issue": older_issue, "younger_issue": younger_issue,
                "older_commit": older_commit, "younger_commit": younger_commit}


def check_speculation(probe: dict, events: list[tuple[str, dict]]) -> tuple[str | None, dict]:
    def matching(kind: str, pc: int) -> list[dict]:
        return [fields for event, fields in events if event == kind and fields.get("pc") == pc]

    dispatched = matching("DISPATCH", probe["wrong_pc"])
    issued = matching("ISSUE", probe["wrong_pc"])
    flushes = matching("FLUSH", probe["branch_pc"])
    evidence = {"dispatched": dispatched, "issued": issued, "flushes": flushes}
    for issue in issued:
        identity, issue_cycle = issue.get("id"), issue.get("cycle")
        allocation = next((item for item in dispatched if item.get("id") == identity), None)
        flush = next((item for item in flushes if issue_cycle is not None and item.get("cycle", -1) > issue_cycle), None)
        if allocation is None or flush is None:
            continue
        associated = [(kind, fields) for kind, fields in events if fields.get("id") == identity]
        if any(kind == "COMMIT" for kind, _ in associated):
            return "wrong-path instruction committed", evidence
        if probe["kind"] in ("mdu", "load", "bad_load", "writeback_load"):
            if any(kind == "COMPLETE" for kind, _ in associated):
                return "wrong-path long operation completed; required coverage is cancellation while in flight", evidence
        evidence.update({"wrong_dispatch": allocation, "wrong_issue": issue, "flush": flush})
        if probe["kind"] in ("load", "bad_load", "writeback_load"):
            drop = next((fields for kind, fields in associated if kind == "DROP_LOAD"
                         and fields.get("cycle", -1) >= flush["cycle"]), None)
            if drop is None or not flush.get("load_pending"):
                return "killed Load was not observed pending at flush and drained afterward", evidence
            replacement = next((item for item in matching("DISPATCH", probe["replacement_pc"])
                                if flush["cycle"] < item.get("cycle", -1) < drop["cycle"]
                                and item.get("pdst") == allocation.get("pdst")
                                and item.get("rd") == allocation.get("rd") == 7
                                and "pdst" in item
                                and any(commit.get("id") == item.get("id")
                                        for commit in matching("COMMIT", probe["replacement_pc"]))), None)
            evidence["drop"] = drop
            evidence["replacement_candidates"] = matching("DISPATCH", probe["replacement_pc"])
            if replacement is None and probe.get("require_reuse", False):
                return "required coverage missing: killed Load's physical destination reused before its stale response drained", evidence
            evidence["replacement"] = replacement
        return None, evidence
    return "wrong-path instruction did not dispatch and issue before the tested branch flushed", evidence


def check_prediction(probe: dict, events: list[tuple[str, dict]]) -> tuple[str | None, dict]:
    commits = [fields for kind, fields in events if kind == "COMMIT" and fields.get("pc") == probe["site_pc"]]
    flushes = {fields["id"]: fields for kind, fields in events
               if kind == "FLUSH" and fields.get("pc") == probe["site_pc"]}
    evidence = {"commits": commits, "flushes": list(flushes.values())}
    if len(commits) != len(probe["target_pcs"]):
        return "prediction probe did not retire the required number of control-flow occurrences", evidence
    for occurrence in probe["required_flushes"]:
        flush = flushes.get(commits[occurrence].get("id"))
        if flush is None or flush.get("target") != probe["target_pcs"][occurrence]:
            return f"prediction recovery missing at occurrence {occurrence} of PC {probe['site_pc']:08x}", evidence
    correct = [commit for commit in commits if commit.get("id") not in flushes]
    evidence["correctly_predicted"] = correct
    if len(correct) < probe["minimum_correct"]:
        return "prediction probe lacks correctly predicted control flow after training", evidence
    return None, evidence


def check_pipeline(requirements: dict, events: list[tuple[str, dict]]) -> tuple[str | None, dict]:
    committed = {fields["id"] for kind, fields in events if kind == "COMMIT"}
    evidence = {"wb_stalls": [], "rename_bypasses": []}

    def completes_once(identity: int) -> bool:
        return (identity in committed
                and sum(kind == "ISSUE" and fields.get("id") == identity for kind, fields in events) == 1
                and sum(kind == "COMPLETE" and fields.get("id") == identity for kind, fields in events) == 1)

    for source in requirements.get("wb_stall_sources", []):
        stall = next((fields for kind, fields in events if kind == "WB_STALL"
                      and fields.get("source") == source and completes_once(fields.get("id"))
                      and any(event == "ISSUE" and item.get("id") == fields.get("id")
                              and item.get("cycle", -1) > fields.get("cycle", -1)
                              for event, item in events)), None)
        if stall is None:
            return f"no committed EX instruction stalled by completion source {source} then executed exactly once", evidence
        evidence["wb_stalls"].append(stall)
    if requirements.get("rename_bypass"):
        bypass = next((fields for kind, fields in events if kind == "RENAME_BYPASS"
                       and completes_once(fields.get("id"))), None)
        if bypass is None:
            return "no committed rename insertion observed concurrent with its source writeback", evidence
        evidence["rename_bypasses"].append(bypass)
    return None, evidence


def run_case(case: Path, simulator: Path, out: Path, latency: int, max_cycles: int,
             result_only: bool, require_ooo: bool, require_speculation: bool = True) -> dict:
    expected_result = int((case / "expected.txt").read_text().strip(), 0)
    machine = RV32.from_image(case / "program.data")
    reference = machine.run()
    metadata = json.loads((case / "meta.json").read_text()) if (case / "meta.json").exists() else {}
    probes = metadata.get("probes", [])
    speculation = metadata.get("speculation", [])
    prediction = metadata.get("prediction", [])
    pipeline = metadata.get("pipeline", {})
    probe_pcs = {probe[key + "_pc"] for probe in probes for key in ("older", "younger", "producer")}
    probe_pcs.update(probe[key + "_pc"] for probe in speculation for key in ("branch", "wrong", "replacement"))
    probe_pcs.update(probe["site_pc"] for probe in prediction)
    observed = []
    folder = out / f"{case.name}-latency{latency}"
    folder.mkdir(parents=True, exist_ok=True)
    command = [str(simulator), str((case / "program.data").resolve()),
               str(expected_result), str(max_cycles), str(latency)]
    errors = []
    commits = 0
    pass_cycles = None
    start = time.monotonic()
    with (folder / "sim.log").open("w") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, errors="replace", bufsize=1)
        assert process.stdout is not None
        for line in process.stdout:
            log.write(line)
            passed = PASS.match(line.strip())
            if passed:
                pass_cycles = int(passed[1])
            try:
                parsed = parse_trace(line)
            except ValueError as error:
                if not errors:
                    errors.append(f"invalid trace value: {error}")
                continue
            if not parsed:
                continue
            kind, fields = parsed
            if pipeline or fields.get("pc") in probe_pcs:
                observed.append((kind, fields))
            if kind != "COMMIT":
                continue
            commits += 1
            if not result_only and not errors:
                try:
                    expected = next(reference)
                except StopIteration:
                    errors.append("extra commit after architectural exit")
                else:
                    mismatch = compare_commit(fields, expected)
                    if mismatch:
                        errors.append(mismatch)
        returncode = process.wait()
    if returncode:
        errors.append(f"simulator exit status {returncode}")
    if pass_cycles is None:
        errors.append("simulator did not report PASS")
    if not result_only and not errors:
        try:
            missing = next(reference)
        except StopIteration:
            if machine.result != expected_result:
                errors.append(f"reference result {machine.result} != expected file {expected_result}")
        else:
            errors.append(f"missing commit {missing.seq} pc={missing.pc:08x}; saw {commits} commits")
    proof = []
    if not result_only and require_ooo and not errors:
        for probe in probes:
            error, evidence = check_ooo(probe, observed)
            proof.append({"probe": probe, "evidence": evidence})
            if error:
                errors.append(error)
    speculation_proof = []
    if not result_only and require_speculation and not errors:
        for probe in speculation:
            error, evidence = check_speculation(probe, observed)
            speculation_proof.append({"probe": probe, "evidence": evidence})
            if error:
                errors.append(error)
    prediction_proof = []
    pipeline_proof = {}
    if not result_only and require_speculation and not errors:
        for probe in prediction:
            error, evidence = check_prediction(probe, observed)
            prediction_proof.append({"probe": probe, "evidence": evidence})
            if error:
                errors.append(error)
        if pipeline:
            error, pipeline_proof = check_pipeline(pipeline, observed)
            if error:
                errors.append(error)
    report = {"case": case.name, "latency": latency, "passed": not errors, "errors": errors,
              "commits": commits, "cycles": pass_cycles, "elapsed_seconds": round(time.monotonic() - start, 3),
              "result_only": result_only, "command": command, "ooo_evidence": proof,
              "speculation_evidence": speculation_proof,
              "prediction_evidence": prediction_proof, "pipeline_evidence": pipeline_proof,
              "checks": {"commits": not result_only, "ooo": not result_only and require_ooo,
                         "speculation": not result_only and require_speculation},
              "image_sha256": hashlib.sha256((case / "program.data").read_bytes()).hexdigest()}
    (folder / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if errors:
        # Keep exact reproduction material even if a later generation replaces
        # the source case directory. The log is already retained above.
        preserved = folder / "failure-case"
        preserved.mkdir(exist_ok=True)
        for source in case.iterdir():
            if source.is_file():
                shutil.copy2(source, preserved / source.name)
        with (folder / "reference.jsonl").open("w") as trace:
            failed_reference = RV32.from_image(case / "program.data")
            for event in failed_reference.run():
                trace.write(json.dumps(asdict(event)) + "\n")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--cases", type=Path, default=Path("build/verification/cases"))
    parser.add_argument("--case", action="append", help="case name or glob; repeatable")
    parser.add_argument("--latencies", default="10", help="comma-separated official RAM latencies")
    parser.add_argument("--max-cycles", type=int, default=100_000_000)
    parser.add_argument("--out", type=Path, default=Path("build/verification/runs"))
    parser.add_argument("--result-only", action="store_true", help="explicitly disable commit and OoO checks")
    parser.add_argument("--no-ooo", action="store_true", help="check commits but skip issue-order proof")
    parser.add_argument("--no-speculation-coverage", action="store_true", help="check commits but skip required wrong-path in-flight/reuse coverage")
    args = parser.parse_args()
    simulator = args.sim.expanduser().resolve()
    if not simulator.is_file():
        parser.error(f"missing simulator {simulator}")
    patterns = args.case or ["*"]
    cases = sorted({path for pattern in patterns for path in args.cases.glob(pattern)
                    if path.is_dir() and (path / "program.data").exists()})
    if not cases:
        parser.error("no cases matched")
    latencies = [int(item) for item in args.latencies.split(",")]
    if any(not 1 <= latency <= 1_000_000 for latency in latencies):
        parser.error("latencies must be in 1..1000000")
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    output = args.out / stamp
    output.mkdir(parents=True)
    results = []
    for case in cases:
        for latency in latencies:
            report = run_case(case, simulator, output, latency, args.max_cycles,
                              args.result_only, not args.no_ooo, not args.no_speculation_coverage)
            results.append(report)
            status = "PASS" if report["passed"] else "FAIL"
            print(f"{status} {case.name} latency={latency} cycles={report['cycles']} commits={report['commits']}", flush=True)
            for error in report["errors"]:
                print(f"  {error}", flush=True)
    summary = {"passed": sum(item["passed"] for item in results), "total": len(results), "results": results}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Results: {summary['passed']}/{summary['total']} passed; logs: {output.resolve()}")
    return int(summary["passed"] != summary["total"])


if __name__ == "__main__":
    raise SystemExit(main())
