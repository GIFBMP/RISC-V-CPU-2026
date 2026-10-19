#!/usr/bin/env python3
"""Audit one V7 Linux run directory and enforce all release acceptance gates."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def artifact(path):
    return {"path": str(path.relative_to(ROOT)), "sha256": sha(path)}


def read(path):
    return json.loads(path.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--memory-directory", default="memory-units")
    args = parser.parse_args()
    runs = args.runs.resolve()
    environment = read(runs / "tool-versions.json")
    assert environment["system"] == "Linux"
    official = (runs / "official-regression.log").read_text()
    assert "Results: 19 passed, 0 failed" in official
    official_cycles = {n: int(c) for n, c in re.findall(r"\[(correctness_[^\]]+)\]\s*PASS cycles=(\d+)", official)}
    assert len(official_cycles) == 19
    performance = {n: (int(i), int(c)) for n, i, c in re.findall(r"^(perf_\w+)\s+(\d+)\s+(\d+)\s+", official, re.M)}
    assert len(performance) == 6
    ipc = math.exp(sum(math.log(i / c) for i, c in performance.values()) / len(performance))
    synth = read(runs / "synth/opt/report.json")
    timing, area = synth["timing"], synth["area"]
    targets = {"ipc": ipc > 1.0985, "frequency": timing["estimated_fmax_mhz"] > 300,
               "area": area["area_um2"] <= 36000}
    assert all(targets.values()), targets
    assert timing["timing_analyzed"] and timing["output_load_ff"] == 5.0
    assert timing["clock_period_ns"] == 2.0 and timing["input_delay_ns"] == timing["output_delay_ns"] == 0.2
    assert synth["abc_constraints"] == {"driving_cell": "BUFx2_ASAP7_75t_R", "output_load_ff": 1.0}
    assert math.isclose(area["area_um2"], area["logic_area_um2"] + area["sram_area_um2"], abs_tol=1e-6)
    trace_manifest = read(runs / "trace/build.json")
    assert trace_manifest["parameters"] == {"TRACE": "1"}
    source = trace_manifest["source_sha256"]
    for name, expected in source.items():
        assert sha(ROOT / name) == expected, f"source changed: {name}"
    cases = {p.name: sha(p / "program.data") for p in (runs / "cases").iterdir() if (p / "program.data").is_file()}
    assert len(cases) == 63
    tests = {}

    def trace_run(name, default=False, perf=False):
        summaries = sorted((runs / name).glob("*/summary.json"))
        assert summaries, name
        path = summaries[-1]
        summary = read(path)
        total = 6 if perf else len(cases) * 3
        assert summary["passed"] == summary["total"] == total, (name, summary["passed"], total)
        expected_matrix = {(case, 10) for case in performance} if perf else {(case, lat) for case in cases for lat in (1, 10, 31)}
        assert {(r["case"], r["latency"]) for r in summary["results"]} == expected_matrix
        for result in summary["results"]:
            assert not result["result_only"] and result["checks"]["commits"]
            assert result["v7_invariants"]["applicable"]
            if default:
                assert result["checks"]["ooo"] and result["checks"]["speculation"]
            if perf:
                assert (result["commits"], result["cycles"]) == performance[result["case"]]
                assert result["image_sha256"] == sha(ROOT / "testcases" / result["case"] / "program.data")
            else:
                assert result["image_sha256"] == cases[result["case"]]
        tests[name] = {"passed": total, "total": total, "latencies": [10] if perf else [1,10,31],
                       "commits_compared": sum(r["commits"] for r in summary["results"]), "summary": artifact(path),
                       "strict_timing_coverage": default,
                       "results": [{k:r[k] for k in ("case", "latency", "cycles", "commits", "image_sha256", "v7_invariants")}
                                   for r in summary["results"]]}
        if default:
            tests[name]["coverage_evidence"] = [{"case":r["case"], "latency":r["latency"],
                **{k:r[k] for k in ("ooo_evidence", "speculation_evidence", "prediction_evidence", "pipeline_evidence",
                   "lsu_evidence", "recovery_evidence", "wide_evidence", "v7_evidence")}}
                for r in summary["results"]]

    trace_run("directed", default=True)
    trace_run("perf-trace", perf=True)
    profiles = {}
    for name in ("small", "scalar", "legacy", "no-early", "single-completion"):
        manifest = read(runs / name / "build.json")
        assert manifest["source_sha256"] == source
        profiles[name] = {"parameters": manifest["parameters"], "build": artifact(runs / name / "build.json"),
                          "simulator_sha256": sha(runs / name / "sim")}
        trace_run(name + "-runs")
        if name in ("legacy", "single-completion"):
            log = runs / (name + "-scc.log")
            assert "Found and expected 0 SCCs." in log.read_text()
            assert "Found and reported 0 problems." in log.read_text()
            profiles[name]["combinational_loop_check"] = {"passed": True, "log": artifact(log),
                "script": artifact(runs / (name + "-scc.ys"))}
    # A single completion port can hold an old ALU in EX while the independent
    # branch lane redirects. Require a real surviving witness at every latency.
    from run_cpu import parse_trace
    from v7_checks import check_v7_probe
    keep_directory = sorted((runs / "single-completion-runs").glob("*/summary.json"))[-1].parent
    kept_evidence = []
    for latency in (1, 10, 31):
        log = keep_directory / f"selective_response_collision-latency{latency}" / "sim.log"
        with log.open() as stream:
            events = [event for line in stream if (event := parse_trace(line))]
        error, evidence = check_v7_probe({"kind": "keep_execution"}, events)
        assert error is None, (latency, error)
        kept_evidence.append({"latency": latency, "evidence": evidence, "log": artifact(log)})
    tests["single-completion-runs"]["kept_execution"] = kept_evidence
    for name, total in (("faults",27), ("writeback-faults",12)):
        path = runs / name / "summary.json"
        summary = read(path)
        assert summary["passed"] == summary["total"] == total and all(r["passed"] for r in summary["results"])
        tests[name] = {"passed": total, "total": total, "summary": artifact(path),
                       "results": [{k:r[k] for k in ("case", "latency", "passed") if k in r} for r in summary["results"]]}
    wb_manifest = read(runs / "writeback/build.json")
    assert all(wb_manifest["source_sha256"].get(p) == h for p,h in source.items())
    assert sha(ROOT / "verification/runners/writeback_fault_sim.cpp") == wb_manifest["source_sha256"]["verification/runners/writeback_fault_sim.cpp"]
    memory_path = runs / args.memory_directory / "summary.json"
    memory = read(memory_path)
    assert memory["complete"] and memory["passed"] == memory["total"] == 69
    assert all(r["passed"] for r in memory["results"])
    for manifest_path in (runs / args.memory_directory).glob("*/build.json"):
        for path, expected in read(manifest_path)["source_sha256"].items():
            assert sha(ROOT / path) == expected, f"memory unit source changed: {path}"
    tests["memory_units"] = {**memory, "summary": artifact(memory_path)}
    frontend = (runs / "execute-frontend-units.log").read_text()
    assert len(re.findall(r"^PASS ", frontend, re.M)) == 32
    assert not re.search(r"(?:^|\s)(?:%?Error|ERROR|FATAL)(?::|\s)", frontend)
    tests["execute_frontend_units"] = {"passed":32, "total":32, "log": artifact(runs / "execute-frontend-units.log")}
    unit_text = (runs / "python-checks.log").read_text()
    assert re.search(r"Ran 46 tests", unit_text) and re.search(r"^OK$", unit_text, re.M)
    tests["checkers"] = {"passed":46, "total":46, "log": artifact(runs / "python-checks.log")}
    assert "SUCCESS!" in (runs / "formal.log").read_text()
    tests["carry_select_equivalence"] = {"passed":True, "scope":"32-bit modular address addition for all two-input values",
                                         "log":artifact(runs / "formal.log")}
    params = {}
    for name, value in re.findall(r"parameter integer (\w+) = ([^,\n]+)", (ROOT / "verilog/student_top.sv").read_text()):
        value = value.strip()
        params[name] = int(value) if value.isdecimal() else params[value]
    from run_v7_linux import source_hashes
    report = {"schema_version":1, "version":"V7", "date_utc":datetime.now(timezone.utc).isoformat(),
              "environment":environment,
              "base_commit":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
              "testcases_commit":subprocess.check_output(["git","-C","testcases","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
              "default_parameters":params, "rtl_and_official_harness_sha256":source,
              "qualification_sources_sha256":source_hashes(),
              "official": {"correctness_passed":19, "correctness_total":19, "correctness_cycles":official_cycles,
                  "log":artifact(runs / "official-regression.log"), "simulator_sha256":sha(runs / "official/sim"),
                  "ipc_geomean":ipc,"latency":10,
                  "performance":[{"case":n,"instructions":i,"cycles":c,"ipc":i/c} for n,(i,c) in performance.items()]},
              "synthesis": {"report":artifact(runs / "synth/opt/report.json"), "abc_constraints":synth["abc_constraints"],
                  "area":area, "timing":{k:v for k,v in timing.items() if k != "critical_paths"}, "tools":synth["tools"]},
              "acceptance": {**targets,"all_met":all(targets.values()),"ipc_margin":ipc-1.0985,
                  "frequency_margin_mhz":timing["estimated_fmax_mhz"]-300, "area_margin_um2":36000-area["area_um2"]},
              "validation":tests, "profiles":profiles, "case_images":cases,
              "scope":"Official 19-case Linux correctness uses the official result protocol. The 6 performance cases and all directed/profile cases compare every commit. Compatibility profiles retain width, forwarding, ownership, retry and recovery invariants while skipping timing obligations specific to the default geometry. STA is ideal-clock/no-parasitics with the original course loads; this is not a routed silicon timing signoff."}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"IPC":ipc, "MHz":timing["estimated_fmax_mhz"], "um2":area["area_um2"],"all_met":True}))


if __name__ == "__main__":
    main()
