#!/usr/bin/env python3
"""Reproduce V7 release qualification inside the course Linux container."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PROFILES = {
    "small": ["ROB_DEPTH=5", "PRF_SIZE=37", "IQ_DEPTH=3", "LSQ_DEPTH=3", "MEM_QUEUE_DEPTH=3",
              "BRANCH_CHECKPOINTS=3", "RAS_DEPTH=3", "DCACHE_WAYS=1", "ICACHE_BYTES=128", "DCACHE_BYTES=128",
              "CACHE_LINE_BYTES=8", "ICACHE_LINE_BYTES=8", "DCACHE_LINE_BYTES=8", "FETCH_QUEUE_DEPTH=5",
              "FETCH_OUTSTANDING=3", "BTB_ENTRIES=5"],
    "scalar": ["FETCH_WIDTH=1", "ISSUE_WIDTH=1", "RENAME_WIDTH=1", "COMMIT_WIDTH=1"],
    "legacy": ["EARLY_RECOVERY=0", "PARALLEL_COMPLETION=0"],
    "no-early": ["SELECT_LOAD=0", "EXECUTE_REDIRECT=0", "REDIRECT_REQUEST=0"],
    "single-completion": ["PARALLEL_COMPLETION=0"],
}


def source_hashes():
    paths = [p for folder in ("verilog", "verification", "scripts") for p in (ROOT / folder).rglob("*")
             if p.suffix in (".sv", ".f", ".py", ".sh", ".cpp")]
    paths += list(ROOT.glob("config*.mk")) + [ROOT / "Makefile"]
    paths += [p for p in (ROOT / "testcases").rglob("*") if p.is_file()
              and p.name in ("program.data", "expected.txt", "metrics.json")]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build/v7") / datetime.now(timezone.utc).strftime("release-%Y%m%d-%H%M%S"))
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--target", choices=("v7", "v7-500"), default="v7",
                        help="enforce the original V7 or the 500 MHz acceptance gates")
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("run this entry point inside the course Linux container")
    out = (ROOT / args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    versions = {"system": platform.system(), "machine": platform.machine(), "python": platform.python_version(),
                "verilator": subprocess.check_output(["verilator", "--version"], text=True).strip()}
    (out / "tool-versions.json").write_text(json.dumps(versions, indent=2) + "\n")
    frozen = source_hashes()
    (out / "source-sha256.json").write_text(json.dumps(frozen, indent=2) + "\n")
    steps = []

    def run(name, command, environment=None):
        print(name, flush=True)
        with (out / (name + ".log")).open("w") as log:
            completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=environment)
        steps.append({"name": name, "command": command, "returncode": completed.returncode})
        (out / "steps.json").write_text(json.dumps(steps, indent=2) + "\n")
        if completed.returncode:
            raise RuntimeError(f"{name} failed; see {out / (name + '.log')}")

    def build(name, params=(), harness=None):
        command = ["python3", "verification/runners/build_trace.py", "--out", str(out / name), "--jobs", str(args.jobs)]
        for parameter in params:
            command += ["--param", parameter]
        if harness:
            command += ["--harness", harness]
        run(name + "-build", command)

    def cases(name, simulator, functional=False):
        command = ["python3", "verification/runners/run_cpu.py", "--sim", str(simulator), "--cases", str(out / "cases"),
                   "--latencies", "1,10,31", "--out", str(out / name)]
        if functional:
            command += ["--no-ooo", "--no-speculation-coverage"]
        run(name, command)

    def check_combinational_loops(name, parameters):
        manifest = json.loads((out / name / "build.json").read_text())
        commands = ["read_verilog -sv -D SYNTHESIS " + json.dumps(str(ROOT / path))
                    for path in manifest["source_sha256"] if Path(path).suffix in (".v", ".sv")]
        for parameter in parameters:
            key, value = parameter.split("=", 1)
            commands.append(f"chparam -set {key} {value} student_top")
        commands += ["hierarchy -check -top student_top", "proc", "flatten", "opt", "scc -expect 0", "check -assert"]
        script = out / (name + "-scc.ys")
        script.write_text("\n".join(commands) + "\n")
        run(name + "-scc", ["yosys", "-s", str(script)])

    run("official-build", ["make", "CONFIG=config.linux.mk", "build", f"BUILD={out / 'official'}", f"JOBS={args.jobs}"])
    run("official-regression", ["make", "CONFIG=config.linux.mk", "test", "perf", f"BUILD={out / 'official'}",
                                f"SIM={out / 'official/sim'}", "MAX_CYCLES=100000000"])
    run("generate", ["python3", "verification/directed/generate.py", "--recovery-mode", "v7", "--out", str(out / "cases")])
    build("trace")
    cases("directed", out / "trace/sim")
    run("perf-trace", ["python3", "verification/runners/run_cpu.py", "--sim", str(out / "trace/sim"), "--cases", "testcases",
                       "--case", "perf_*", "--latencies", "10", "--out", str(out / "perf-trace")])
    run("faults", ["python3", "verification/runners/run_faults.py", "--sim", str(out / "trace/sim"),
                   "--latencies", "1,10,31", "--out", str(out / "faults")])
    for name, parameters in PROFILES.items():
        build(name, parameters)
        cases(name + "-runs", out / name / "sim", functional=True)
        if "PARALLEL_COMPLETION=0" in parameters:
            check_combinational_loops(name, parameters)
    build("writeback", harness="verification/runners/writeback_fault_sim.cpp")
    run("writeback-faults", ["python3", "verification/runners/run_writeback_faults.py", "--sim", str(out / "writeback/sim"),
                            "--out", str(out / "writeback-faults"), "--latencies", "1,10,31", "--recovery-mode", "v7"])
    run("python-checks", ["python3", "-m", "unittest", "discover", "-s", "verification/runners", "-p", "test_*.py"])
    run("case-audit", ["python3", "verification/runners/audit_cases.py", "--cases", str(out / "cases")])
    import os
    environment = {**os.environ, "CPU2026_LINUX_UNIT_BUILD": str(out / "execute-frontend-units"), "CPU2026_UNIT_JOBS": str(args.jobs)}
    run("execute-frontend-units", ["sh", "verification/runners/run_linux_units.sh"], environment)
    run("memory-units", ["python3", "verification/runners/run_linux_memory.py", "--out", str(out / "memory-units"), "--jobs", str(args.jobs)])
    run("formal", ["yosys", "-p", "read_verilog -sv verilog/common/address_adder.sv verification/formal/v7_address_equivalence.sv; prep -top address_equivalence -flatten; sat -verify -prove ok 1 -show-inputs"])
    run("alu-formal", ["yosys", "-p", "read_verilog -sv verilog/common/address_adder.sv verilog/execute/alu.sv verification/formal/v7_alu_equivalence.sv; prep -top alu_equivalence -flatten; sat -verify -prove ok 1 -show-inputs"])
    run("load-immediate-formal", ["yosys", "-p", "read_verilog -sv verilog/common/address_adder.sv verilog/execute/decoder.sv verification/formal/v7_load_immediate_equivalence.sv; prep -top load_immediate_equivalence -flatten; memory_map; opt; sat -verify -prove ok 1 -show-inputs"])
    run("store-align-formal", ["yosys", "-p", "read_verilog -sv verilog/common/store_byte_align.sv verification/formal/v7_store_align_equivalence.sv; prep -top store_align_equivalence -flatten; sat -verify -prove ok 1 -show-inputs"])
    for width in (1, 3, 5, 12, 16, 24, 32):
        run(f"scheduler-formal-{width}", ["yosys", "-p",
            "read_verilog -sv verilog/common/zero_one_tree.sv verification/formal/v7_scheduler_predicates.sv; "
            f"chparam -set WIDTH {width} scheduler_predicates; prep -top scheduler_predicates -flatten; "
            "sat -verify -prove ok 1 -show-inputs"])
        run(f"forward-formal-{width}", ["yosys", "-p",
            "read_verilog -sv verilog/common/youngest_match.sv verification/formal/v7_forward_equivalence.sv; "
            f"chparam -set WIDTH {width} forward_equivalence; prep -top forward_equivalence -flatten; "
            "sat -verify -prove ok 1 -show-inputs"])
    run("synth", ["make", "CONFIG=config.linux.mk", "synth", f"SYNTH_OUT={out / 'synth'}", "MODE=opt"])
    if source_hashes() != frozen:
        raise RuntimeError("sources changed during qualification; results are not one frozen release")
    run("acceptance", ["python3", "verification/runners/collect_v7_results.py", "--runs", str(out),
                       "--out", str(out / "results.json"), "--target", args.target])
    print(f"V7 qualification passed: {out / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
