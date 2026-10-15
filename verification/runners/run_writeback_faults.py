#!/usr/bin/env python3
"""CPU-level one-shot writeback faults, including a killed speculative request.

Requires a TRACE=1 WB-enabled simulator built with writeback_fault_sim.cpp.
Official-simulator regressions remain separate; this harness adds deliberate
SLVERR injection and verifies external committed bytes before exit AW.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import sys

from run_cpu import compare_commit, parse_trace, run_case as run_architectural_case
from run_faults import FaultCase, run_case as run_fault_case, write_case
from rv32_reference import RV32

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "directed"))
from generate import Program, save, wrong_path


def architectural_fault(write: bool) -> FaultCase:
    program = Program("writeback_store_fault" if write else "writeback_load_fault",
                      "Writeback error belongs to the current triggering request, not an earlier retired Store")
    for offset in (0, 4, 8, 12):
        program.li(11, 0x76543210 + offset)
        program.store("sw", 11, 31, offset)
    program.li(1, 0x80000000 if write else 0xF0000000)
    fault_pc = program.pc
    if write:
        program.store("sw", 11, 1)
    else:
        program.load("lw", 7, 1)
    program.resolve()
    return FaultCase(program.name, program.description, tuple(program.words), 5 if write else 4, fault_pc)


def buffered_store_fault() -> FaultCase:
    program = Program("buffered_ram_store_fault",
                      "A retired RAM Store reports its saved PC after redirect and ROB slot reuse")
    program.li(25, 0)
    program.jal(0, "compute")
    program.label("initialize")
    # Four congruent dirty lines fill the default four ways. The next Store
    # evicts the first line, whose second writeback word gets one SLVERR.
    for index in range(4):
        program.li(1, 0x10000 + index * 0x10000)
        program.li(11, 0x76543210 + index)
        program.store("sw", 11, 1)
    program.li(25, 1)
    program.li(1, 0x50000)
    fault_pc = program.pc
    program.store("sw", 11, 1)
    program.branch("beq", 0, 0, "compute")
    program.store("sw", 0, 31)
    program.label("compute")
    # This code was warmed before initialization. The deliberately delayed
    # injected error allows more than one ROB revolution of younger commits.
    for index in range(64):
        program.i("addi", 28, 28, index + 1)
    program.branch("beq", 25, 0, "initialize")
    program.finish()
    program.resolve()
    return FaultCase(program.name, program.description, tuple(program.words), 5, fault_pc)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=Path("build/verification/writeback-faults"))
    parser.add_argument("--latencies", default="1,10,31")
    args = parser.parse_args()
    simulator, output = args.sim.resolve(), args.out.resolve()
    latencies = [int(value) for value in args.latencies.split(",")]
    if not latencies or any(not 1 <= value <= 1_000_000 for value in latencies):
        parser.error("latencies must be in 1..1000000")
    if not simulator.is_file():
        parser.error(f"missing simulator {simulator}")
    output.mkdir(parents=True, exist_ok=True)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.environ["CPU_TEST_FAULT_WRITE"] = "0x10004"
    os.environ.pop("CPU_TEST_FAULT_EXTRA_DELAY", None)
    os.environ.pop("CPU_TEST_EXPECT_MEMORY", None)
    results = []
    for write in (False, True):
        case = architectural_fault(write)
        image = write_case(case, output / "cases" / case.name)
        for latency in latencies:
            folder = output / f"{case.name}-latency{latency}"
            result = run_fault_case(case, image, simulator, folder, latency, 100_000, 30)
            log = (folder / "sim.log").read_text()
            if log.count("CPU_BUS WRITE_ERROR ") != 1:
                result["errors"].append("required one-shot writeback error was not observed exactly once")
            if "CPU_BUS EXIT_RAM_VISIBLE " in log:
                result["errors"].append("architectural writeback error allowed exit MMIO onto AXI")
            reference = RV32.from_image(image)
            expected_commits = []
            while reference.pc != case.pc:
                expected_commits.append(reference.step())
            # Store trace is intentionally emitted at request acceptance even
            # when the later response faults; Load must not retire on error.
            if write:
                expected_commits.append(reference.step())
            commits = [event[1] for line in log.splitlines() if (event := parse_trace(line)) is not None
                       and event[0] == "COMMIT"]
            if len(commits) != len(expected_commits):
                result["errors"].append(f"fault prefix has {len(commits)} commits; expected {len(expected_commits)}")
            for actual, expected_commit in zip(commits, expected_commits):
                mismatch = compare_commit(actual, expected_commit)
                if mismatch:
                    result["errors"].append(mismatch)
                    break
            result["commits"] = len(commits)
            result["passed"] = not result["errors"]
            (folder / "result.json").write_text(json.dumps(result, indent=2) + "\n")
            results.append(result)
            print(f"{'PASS' if result['passed'] else 'FAIL'} {case.name} latency={latency}: {result['errors']}", flush=True)

    program = wrong_path("writeback_load")
    save(program, output / "cases")
    case_path = output / "cases" / program.name
    machine = RV32.from_image(case_path / "program.data")
    list(machine.run())
    expected = output / "expected-external-memory.txt"
    expected.write_text("".join(f"{address:08x} {machine.memory.get(address, 0):02x}\n"
                                for address in range(0x10000, 0x10010)))
    os.environ["CPU_TEST_EXPECT_MEMORY"] = str(expected)
    for latency in latencies:
        result = run_architectural_case(case_path, simulator, output, latency, 100_000,
                                       result_only=False, require_ooo=True, require_speculation=True)
        folder = output / f"{program.name}-latency{latency}"
        log = (folder / "sim.log").read_text()
        if log.count("CPU_BUS WRITE_ERROR ") != 1 or "CPU_BUS EXIT_RAM_VISIBLE " not in log:
            result["errors"].append("missing injected error or external RAM visibility proof")
        evidence = result["speculation_evidence"]
        wrong_id = evidence[0]["evidence"].get("wrong_issue", {}).get("id") if evidence else None
        responses = [event for line in log.splitlines() if (event := parse_trace(line)) is not None
                     and event[0] == "MEM_RESPONSE" and event[1].get("id") == wrong_id]
        if len(responses) != 1 or responses[0][1].get("write") != 0 or responses[0][1].get("killed") != 1:
            result["errors"].append("faulting speculative load did not drain as exactly one killed MEM_RESPONSE")
        result["passed"] = not result["errors"]
        (folder / "report.json").write_text(json.dumps(result, indent=2) + "\n")
        results.append(result)
        print(f"{'PASS' if result['passed'] else 'FAIL'} {program.name} latency={latency}: {result['errors']}", flush=True)

    # Buffered RAM Stores deliberately have an asynchronous diagnostic contract.
    # Keep the exact precise-prefix checks above intact; here every observed
    # commit must remain a valid prefix, including younger retired instructions.
    os.environ.pop("CPU_TEST_EXPECT_MEMORY", None)
    os.environ["CPU_TEST_FAULT_EXTRA_DELAY"] = "256"
    case = buffered_store_fault()
    image = write_case(case, output / "cases" / case.name)
    for latency in latencies:
        folder = output / f"{case.name}-latency{latency}"
        result = run_fault_case(case, image, simulator, folder, latency, 100_000, 30)
        log = (folder / "sim.log").read_text()
        events = [event for line in log.splitlines() if (event := parse_trace(line)) is not None]
        commits = [fields for kind, fields in events if kind == "COMMIT"]
        reference = RV32.from_image(image)
        for actual in commits:
            mismatch = compare_commit(actual, reference.step())
            if mismatch:
                result["errors"].append(mismatch)
                break
        trigger = next((item for item in commits if item["pc"] == case.pc), None)
        response = next((fields for kind, fields in events if kind == "MEM_RESPONSE" and trigger
                         and fields["id"] == trigger["id"]), None)
        younger = [item for item in commits if trigger and item["seq"] > trigger["seq"]]
        intervening_flush = next((fields for kind, fields in events if kind == "FLUSH" and trigger and response
                                 and trigger["cycle"] < fields["cycle"] < response["cycle"]), None)
        if not trigger or not response or response.get("killed") or response.get("write") != 1:
            result["errors"].append("buffered Store did not retain its committed identity through the error response")
        if len(younger) < 16 or not intervening_flush:
            result["errors"].append("required younger retirement/ROB reuse and redirect before asynchronous fault were absent")
        if log.count("CPU_BUS WRITE_ERROR ") != 1 or "buffered_store=1" not in log:
            result["errors"].append("missing exactly one injected writeback error and explicit buffered Store diagnostic")
        if "CPU_BUS EXIT_RAM_VISIBLE " in log or any(kind == "MEM_REQUEST" and fields.get("addr") == 0x80000000
                                                    for kind, fields in events):
            result["errors"].append("exit escaped the older buffered Store error barrier")
        result.update({"commits": len(commits), "younger_commits": len(younger),
                       "buffered_store": trigger, "response": response, "intervening_flush": intervening_flush,
                       "passed": not result["errors"]})
        (folder / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        results.append(result)
        print(f"{'PASS' if result['passed'] else 'FAIL'} {case.name} latency={latency}: {result['errors']}", flush=True)
    summary = {"simulator": str(simulator), "simulator_sha256": hashlib.sha256(simulator.read_bytes()).hexdigest(),
               "passed": sum(result["passed"] for result in results), "total": len(results), "results": results}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Results: {summary['passed']}/{summary['total']}; {output / 'summary.json'}")
    return int(summary["passed"] != summary["total"])


if __name__ == "__main__":
    raise SystemExit(main())
