#!/usr/bin/env python3
"""Run the complete memory/backpressure/noise matrix using Linux Verilator."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
MEMORY = ["scripts/ram/sram_fakeram.sv", "verilog/bus/axi_lite_bridge.sv",
          "verilog/memory/blocking_cache.sv", "verilog/memory/icache_pipeline.sv",
          "verilog/memory/dcache_writeback.sv", "verilog/memory/memory_system.sv"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build/v7/linux-memory"))
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    out = (ROOT / args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    builds, results = {}, []
    (out / "summary.json").write_text(json.dumps({"passed": 0, "total": 0, "complete": False, "results": []}) + "\n")

    def run(name, top, parameters, sources, plusargs=(), banners=()):
        key = (top, tuple(sorted(parameters.items())), tuple(sources))
        if key not in builds:
            folder = out / name
            folder.mkdir(parents=True, exist_ok=True)
            command = ["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", "--top-module", top,
                       "--Mdir", str(folder / "obj"), "-o", str(folder / "sim"), "-j", str(args.jobs),
                       *[f"-G{k}={v}" for k, v in parameters.items()], *sources]
            (folder / "build.json").write_text(json.dumps({"command": command,
                "source_sha256": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in sources}}, indent=2) + "\n")
            with (folder / "compile.log").open("w") as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            builds[key] = folder / "sim"
        simulator = builds[key]
        completed = subprocess.run([str(simulator), *plusargs], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log = out / (name + ".log")
        log.write_text(completed.stdout)
        passed = (completed.returncode == 0 and not re.search(r"(?:^|\s)(?:%?Error|ERROR|FATAL)(?::|\s)", completed.stdout)
                  and all(banner in completed.stdout for banner in (banners or ("PASS ",))))
        results.append({"name": name, "passed": passed, "simulator": str(simulator.relative_to(ROOT)),
                        "parameters": parameters, "arguments": list(plusargs), "log": str(log.relative_to(ROOT))})
        (out / "summary.json").write_text(json.dumps({"passed": sum(r["passed"] for r in results),
            "total": len(results), "complete": False, "results": results}, indent=2) + "\n")
        print(f"{'PASS' if passed else 'FAIL'} {name}", flush=True)
        if not passed:
            raise RuntimeError(f"{name}: see {log}\n{completed.stdout[-4000:]}")

    # These shapes mirror run_writeback_memory.sh, including separate read and
    # write timing, line sizes beyond the bridge credit count, and V7 geometry.
    shapes = [(1,256,16,0,0,0), (2,256,16,0,0,0), (4,256,16,0,0,0),
              (4,256,64,0,0,0), (4,1024,128,0,0,0), (2,4096,16,0,0,0),
              (4,4096,16,0,0,0), (4,16384,64,0,0,0), (4,16384,128,0,0,0),
              (4,256,16,1,0,0), (4,256,16,0,1,0), (1,256,16,1,1,0),
              (2,256,16,1,1,0), (4,256,16,1,1,0), (4,16384,128,1,1,0),
              (4,256,16,0,0,1), (1,256,16,1,1,1), (2,256,16,1,1,1),
              (4,16384,128,1,1,1), (4,16384,256,1,1,1), (4,32768,256,1,1,1)]
    for index, (ways, size, line, fast_d, fast_i, stores) in enumerate(shapes):
        params = dict(DCACHE_WAYS=ways, DCACHE_BYTES=size, CACHE_LINE_BYTES=line,
                      ICACHE_LINE_BYTES=128 if line == 256 else line,
                      FAST_HIT_RESPONSE=fast_d, FAST_INSTRUCTION_RESPONSE=fast_i,
                      PIPELINED_STORE_HITS=stores, FETCH_WIDTH=2 if size == 32768 else 1)
        for fast in (False, True):
            run(f"writeback-{index}-{'fast' if fast else 'slow'}", "writeback_memory_tb", params,
                MEMORY + ["verification/unit/writeback_memory_tb.sv"],
                ("+READ_LATENCY=1", "+FAST_WRITE") if fast else ("+READ_LATENCY=64",), ("PASS writeback_memory:",))
    for fast_d in (0, 1):
        for stores in (0, 1):
            for fast in (False, True):
                run(f"dcache-noise-{fast_d}-{stores}-{fast}", "dcache_preread_tb",
                    dict(FAST_HIT_RESPONSE=fast_d, PIPELINED_STORE_HITS=stores),
                    MEMORY + ["verification/unit/writeback_memory_tb.sv", "verification/unit/dcache_preread_tb.sv"],
                    ("+READ_LATENCY=1", "+FAST_WRITE") if fast else ("+READ_LATENCY=64",),
                    ("PASS writeback_memory:", "PASS dcache_preread:"))
    for fast_i in (0, 1):
        for fast in (False, True):
            run(f"icache-noise-{fast_i}-{fast}", "icache_preread_tb", dict(FAST_INSTRUCTION_RESPONSE=fast_i),
                MEMORY + ["verification/unit/writeback_memory_tb.sv", "verification/unit/icache_preread_tb.sv"],
                ("+READ_LATENCY=1", "+FAST_WRITE") if fast else ("+READ_LATENCY=64",),
                ("PASS writeback_memory:", "PASS icache_preread:"))
        for line in (8, 128):
            run(f"wide-memory-{fast_i}-{line}", "writeback_memory_tb",
                dict(FETCH_WIDTH=2, ICACHE_LINE_BYTES=line, FAST_INSTRUCTION_RESPONSE=fast_i),
                MEMORY + ["verification/unit/writeback_memory_tb.sv"])
    for line, latency in ((16,64), (16,1), (64,64)):
        run(f"memory-system-{line}-{latency}", "memory_system_tb", dict(CACHE_LINE_BYTES=line),
            MEMORY + ["verification/unit/memory_system_tb.sv"], (f"+READ_LATENCY={latency}",))
    for queue, outstanding, bypass, direct in ((16,4,1,1), (8,4,1,1), (5,3,1,1), (3,5,1,1),
                                               (2,1,1,1), (1,1,1,1), (8,4,0,1), (8,4,1,0)):
        run(f"wide-fetch-{queue}-{outstanding}-{bypass}-{direct}", "wide_fetch_tb",
            dict(QUEUE_DEPTH=queue, OUTSTANDING=outstanding, BYPASS=bypass, DIRECT=direct),
            ["verilog/frontend/fetch_frontend.sv", "verification/unit/wide_fetch_tb.sv"])
    (out / "summary.json").write_text(json.dumps({"passed": sum(r["passed"] for r in results),
        "total": len(results), "complete": True, "results": results}, indent=2) + "\n")


if __name__ == "__main__":
    main()
