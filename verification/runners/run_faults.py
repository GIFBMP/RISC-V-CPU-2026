#!/usr/bin/env python3
"""Check precise CPU fault diagnostics with the unmodified course simulator.

Expected failures must have a nonzero exit status AND the exact expected
``CPU fault=N pc=XXXXXXXX`` diagnostic. A timeout, generic assertion, or unrelated
abort is a test failure. Generated images, full logs, and JSON results are saved.
This runner targets macOS/Linux and disables core dumps before launching the DUT.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
FAULT = re.compile(r"\bCPU fault=(\d+)\s+pc=(?:0x)?([0-9a-fA-F]{8})\b")
FAULT_NAMES = {1: "fetch", 2: "illegal", 3: "alignment", 4: "load", 5: "store"}


@dataclass(frozen=True)
class FaultCase:
    name: str
    description: str
    words: tuple[int, ...]
    fault: int
    pc: int


def i_type(opcode: int, rd: int, funct3: int, rs1: int, immediate: int = 0) -> int:
    if not -2048 <= immediate <= 2047:
        raise ValueError("I-type immediate out of range")
    return ((immediate & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def s_type(funct3: int, rs1: int, rs2: int, immediate: int = 0) -> int:
    if not -2048 <= immediate <= 2047:
        raise ValueError("S-type immediate out of range")
    immediate &= 0xFFF
    return ((immediate >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | \
        (funct3 << 12) | ((immediate & 31) << 7) | 0x23


def fault_cases() -> tuple[FaultCase, ...]:
    nop = i_type(0x13, 0, 0, 0)
    ram_end_in_x1 = 0x100000B7  # lui x1,0x10000 -> first address outside RAM
    exit_address_in_x1 = 0x800000B7  # lui x1,0x80000
    return (
        FaultCase("illegal_instruction", "Reserved instruction after one valid NOP",
                  (nop, 0xFFFFFFFF), 2, 4),
        FaultCase("load_outside_ram", "Aligned LW at 0x10000000 on the valid path",
                  (ram_end_in_x1, i_type(0x03, 2, 2, 1)), 4, 4),
        FaultCase("store_outside_ram", "Aligned SW at 0x10000000 on the valid path",
                  (ram_end_in_x1, i_type(0x13, 2, 0, 0, 7), s_type(2, 1, 2)), 5, 8),
        FaultCase("read_exit_mmio_x0", "Reading exit MMIO faults even with rd=x0",
                  (exit_address_in_x1, i_type(0x03, 0, 2, 1)), 4, 4),
        FaultCase("misaligned_lw", "LW from 0x102 must report the load instruction PC",
                  (i_type(0x13, 1, 0, 0, 0x102), i_type(0x03, 2, 2, 1)), 3, 4),
        FaultCase("misaligned_sh", "SH to 0x101 must fault before any external Store",
                  (i_type(0x13, 1, 0, 0, 0x101), s_type(1, 1, 0)), 3, 4),
        FaultCase("misaligned_jal", "JAL x0,+2 at PC=4 targets a non-word-aligned PC",
                  (nop, 0x0020006F), 3, 4),
        FaultCase("misaligned_jalr", "JALR target=6 remains misaligned after clearing bit 0",
                  (i_type(0x13, 1, 0, 0, 6), i_type(0x67, 0, 0, 1)), 3, 4),
        FaultCase("fetch_outside_ram", "JALR to 0x10000000 must report the target fetch PC",
                  (ram_end_in_x1, i_type(0x67, 0, 0, 1)), 1, 0x10000000),
    )


def write_case(case: FaultCase, directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    # If the expected fault is incorrectly ignored, park on a legal instruction
    # instead of accidentally accepting a later zero-filled illegal instruction.
    words = (*case.words, 0x0000006F)  # jal x0,0
    image = directory / "program.data"
    payload = b"".join(word.to_bytes(4, "little") for word in words)
    lines = [f"# {case.description}", "@00000000"]
    lines += [" ".join(f"{byte:02x}" for byte in payload[start:start + 16])
              for start in range(0, len(payload), 16)]
    image.write_text("\n".join(lines) + "\n", encoding="utf-8")
    metadata = {"name": case.name, "description": case.description,
                "expected_fault": case.fault, "expected_fault_name": FAULT_NAMES[case.fault],
                "expected_pc": f"{case.pc:08x}",
                "words": [{"pc": f"{index * 4:08x}", "instruction": f"{word:08x}"}
                          for index, word in enumerate(words)]}
    (directory / "expected.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return image


def assess_exit(returncode: int | None, output: str, case: FaultCase) -> tuple[list[str], list[dict]]:
    errors = []
    diagnostics = [{"fault": int(match[1]), "pc": f"{int(match[2], 16):08x}"}
                   for match in FAULT.finditer(output)]
    if returncode is None:
        errors.append("simulator did not finish")
    elif returncode == 0:
        errors.append("simulator exited successfully instead of reporting a CPU fault")
    if not diagnostics:
        errors.append("missing CPU fault diagnostic; an unrelated abort/timeout does not pass")
    for diagnostic in diagnostics:
        if diagnostic["fault"] != case.fault or int(diagnostic["pc"], 16) != case.pc:
            errors.append(f"wrong diagnostic: fault={diagnostic['fault']} pc={diagnostic['pc']}; "
                          f"expected fault={case.fault} pc={case.pc:08x}")
    if re.search(r"^PASS\b", output, re.MULTILINE):
        errors.append("simulator reported a successful program exit")
    return errors, diagnostics


def run_case(case: FaultCase, image: Path, simulator: Path, directory: Path,
             latency: int, max_cycles: int, timeout: float) -> dict:
    directory.mkdir(parents=True, exist_ok=True)
    command = [str(simulator), str(image), "0", str(max_cycles), str(latency)]
    started = time.monotonic()
    returncode = None
    execution_error = None
    output = ""
    try:
        process = subprocess.run(command, cwd=directory, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, errors="replace",
                                 timeout=timeout, check=False)
        returncode, output = process.returncode, process.stdout
    except subprocess.TimeoutExpired as error:
        raw = error.stdout or b""
        output = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
        execution_error = f"wall-clock timeout after {timeout:g} seconds"
    except OSError as error:
        execution_error = f"could not execute simulator: {error}"
    (directory / "sim.log").write_text(output, encoding="utf-8")
    errors, diagnostics = assess_exit(returncode, output, case)
    if execution_error:
        errors.insert(0, execution_error)
    result = {"case": case.name, "latency": latency, "max_cycles": max_cycles,
              "command": command, "expected_fault": case.fault,
              "expected_pc": f"{case.pc:08x}", "returncode": returncode,
              "diagnostics": diagnostics, "passed": not errors, "errors": errors,
              "elapsed_seconds": round(time.monotonic() - started, 6),
              "image": str(image), "log": str(directory / "sim.log")}
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, required=True, help="simulator executable for this host OS")
    parser.add_argument("--out", type=Path, default=ROOT / "build/verification/faults")
    parser.add_argument("--latencies", default="1,10,31", help="comma-separated external RAM latencies")
    parser.add_argument("--max-cycles", type=int,
                        help="per-run cycle limit; default max(10000,16*latency+1000)")
    parser.add_argument("--timeout", type=float, default=30.0, help="wall-clock limit per run in seconds")
    args = parser.parse_args()
    simulator = args.sim.expanduser().resolve()
    if not simulator.is_file() or not os.access(simulator, os.X_OK):
        parser.error(f"simulator must be an executable file: {simulator}")
    try:
        latencies = list(dict.fromkeys(int(item.strip()) for item in args.latencies.split(",")))
    except ValueError:
        parser.error("--latencies must contain comma-separated positive integers")
    if not latencies or any(not 1 <= latency <= 1_000_000 for latency in latencies):
        parser.error("latencies must be in 1..1000000")
    if args.max_cycles is not None and not 1 <= args.max_cycles < 2**63:
        parser.error("--max-cycles must be in 1..2^63-1")
    if not 0 < args.timeout <= 86400:
        parser.error("--timeout must be positive and at most 86400 seconds")

    # Limit applies to this runner and its children only, not the invoking shell.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    out = args.out.expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = []
    started_at = datetime.now(timezone.utc).isoformat()
    for case in fault_cases():
        image = write_case(case, out / "cases" / case.name)
        for latency in latencies:
            limit = args.max_cycles or max(10_000, 16 * latency + 1_000)
            result = run_case(case, image, simulator,
                              out / "runs" / f"{case.name}-latency{latency}",
                              latency, limit, args.timeout)
            results.append(result)
            status = "PASS" if result["passed"] else "FAIL"
            print(f"{status} {case.name} latency={latency} "
                  f"fault={case.fault} pc={case.pc:08x}", flush=True)
            for error in result["errors"]:
                print(f"  {error}", flush=True)
    passed = sum(result["passed"] for result in results)
    summary = {"started_at_utc": started_at, "simulator": str(simulator),
               "simulator_sha256": hashlib.sha256(simulator.read_bytes()).hexdigest(),
               "core_dumps_disabled": True, "passed": passed,
               "failed": len(results) - passed, "total": len(results), "results": results}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"Results: {passed} passed, {len(results) - passed} failed; {out / 'summary.json'}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
