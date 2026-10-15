#!/usr/bin/env python3
"""Check reference answers against official cases and optional GNU encoding.

The assembler check is optional: ordinary generation and CPU regression use
only Python's standard library. It cross-checks the custom encoder with an
independent tool, not another copy of the same encoder.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from rv32_reference import RV32


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, default=Path("testcases"))
    parser.add_argument("--assembler", action="store_true", help="also compare program.words with GNU-assembled program.S")
    parser.add_argument("--prefix", default="riscv64-elf-")
    args = parser.parse_args()
    failures = 0
    if args.assembler:
        for tool in ("as", "ld", "objcopy"):
            if not shutil.which(args.prefix + tool):
                parser.error(f"missing {args.prefix + tool}")
    for case in sorted(args.cases.iterdir()):
        if not case.is_dir() or not (case / "program.data").exists():
            continue
        machine = RV32.from_image(case / "program.data")
        for _ in machine.run():
            pass
        expected = int((case / "expected.txt").read_text().strip(), 0)
        instructions = json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
        errors = []
        if (machine.result, machine.retired) != (expected, instructions):
            errors.append(f"result/count actual={(machine.result, machine.retired)} expected={(expected, instructions)}")
        if args.assembler:
            if not (case / "program.words").exists():
                errors.append("assembly audit requires generated program.words")
            else:
                with tempfile.TemporaryDirectory(prefix="cpu2026-encode-") as temp:
                    root = Path(temp)
                    subprocess.run([args.prefix + "as", "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-o", str(root / "case.o"), str(case / "program.S")], check=True, capture_output=True)
                    subprocess.run([args.prefix + "ld", "-melf32lriscv", "--no-relax", "-Ttext=0", "-o", str(root / "case.elf"), str(root / "case.o")], check=True, capture_output=True)
                    subprocess.run([args.prefix + "objcopy", "-O", "binary", "-j", ".text", str(root / "case.elf"), str(root / "case.bin")], check=True, capture_output=True)
                    actual = (root / "case.bin").read_bytes()
                    encoded = b"".join(int(line.split(":")[1], 16).to_bytes(4, "little") for line in (case / "program.words").read_text().splitlines())
                    if actual != encoded:
                        first = next((index for index, (a, b) in enumerate(zip(actual, encoded)) if a != b), min(len(actual), len(encoded)))
                        errors.append(f"GNU assembler mismatch at byte {first:#x}; sizes {len(actual)}/{len(encoded)}")
        failures += bool(errors)
        print(f"{'FAIL' if errors else 'PASS'} {case.name} instructions={machine.retired}" + ("; " + "; ".join(errors) if errors else ""), flush=True)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
