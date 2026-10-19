#!/usr/bin/env python3
"""Probe forward progress when a Store's data producer is still queued.

The second DIV waits for the shared MDU. Its younger Store may calculate an
address first. A following aliasing Load must allow the DIV to issue; a
non-aliasing Load may proceed. Both programs are checked by the RV32 reference.
"""
from pathlib import Path
import argparse

from generate import Program, save


def build(alias: bool, store_op: str = "sw", load_op: str = "lw", offset: int = 0) -> Program:
    width = {"sw": "", "sb": "byte_", "sh": "half_"}[store_op]
    program = Program(
        "late_store_" + width + ("alias" if alias else "nonalias"),
        "Late Store data waits for a queued DIV; a Load must not block the producer",
    )
    program.li(1, 0x12345678)
    program.li(2, 19)
    program.r("div", 3, 1, 2)
    program.label("producer")
    program.r("div", 4, 1, 2)
    program.label("store")
    program.store(store_op, 4, 31, offset)
    program.label("load")
    program.load(load_op, 5, 31, offset if alias else (4 if store_op == "sw" else 8))
    for register in (3, 4, 5):
        program.checksum(register)
    program.finish()
    return program


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build/v7-design/probes"))
    args = parser.parse_args()
    for store_op, load_op, offset in (("sw", "lw", 0), ("sb", "lbu", 1), ("sh", "lhu", 2)):
        for alias in (True, False):
            result = save(build(alias, store_op, load_op, offset), args.out)
            print(f"{result['name']}: {result['dynamic_instructions']} instructions")


if __name__ == "__main__":
    main()
