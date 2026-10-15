#!/usr/bin/env python3
"""Small, architectural RV32IM oracle, independent of the RTL and assembler.

No privileged instructions or misaligned accesses are modeled. Uninitialized
RAM bytes are zero, matching the course simulator. A full-word MMIO store is
recorded as a retirement before execution ends.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
from pathlib import Path
from typing import Iterator

MASK = 0xFFFFFFFF
RAM_LIMIT = 0x10000000
EXIT_ADDRESS = 0x80000000


def signed(value: int, bits: int = 32) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


class ArchitecturalFault(ValueError):
    pass


@dataclass(frozen=True)
class Commit:
    seq: int
    pc: int
    insn: int
    rd: int = 0
    value: int = 0
    store: int = 0
    addr: int = 0
    data: int = 0
    strb: int = 0


class RV32:
    def __init__(self, memory: dict[int, int] | None = None):
        self.memory = dict(memory or {})
        self.regs = [0] * 32
        self.pc = 0
        self.retired = 0
        self.result: int | None = None

    @classmethod
    def from_image(cls, path: Path) -> "RV32":
        memory: dict[int, int] = {}
        address = 0
        for line in path.read_text().splitlines():
            for token in line.split("#", 1)[0].split():
                if token.startswith("@"):
                    address = int(token[1:], 16)
                else:
                    value = int(token, 16)
                    if not 0 <= value <= 255 or not 0 <= address < RAM_LIMIT:
                        raise ValueError(f"invalid image byte/address at {address:#x}")
                    memory[address] = value
                    address += 1
        return cls(memory)

    def read(self, address: int, size: int) -> int:
        if address % size or not 0 <= address <= RAM_LIMIT - size:
            raise ArchitecturalFault(f"invalid {size}-byte read at {address:#010x}")
        return sum(self.memory.get(address + offset, 0) << (offset * 8)
                   for offset in range(size))

    def step(self) -> Commit:
        if self.result is not None:
            raise ArchitecturalFault("execution after exit")
        pc = self.pc
        insn = self.read(pc, 4)
        opcode = insn & 0x7F
        rd = (insn >> 7) & 31
        funct3 = (insn >> 12) & 7
        rs1, rs2 = (insn >> 15) & 31, (insn >> 20) & 31
        funct7 = insn >> 25
        a, b = self.regs[rs1], self.regs[rs2]
        imm_i = signed(insn >> 20, 12)
        next_pc = (pc + 4) & MASK
        value: int | None = None
        store = address = data = strobe = 0

        def illegal() -> None:
            raise ArchitecturalFault(f"illegal instruction {insn:08x} at {pc:08x}")

        if opcode == 0x37:
            value = insn & 0xFFFFF000
        elif opcode == 0x17:
            value = pc + (insn & 0xFFFFF000)
        elif opcode == 0x6F:
            immediate = ((insn >> 31) << 20) | (((insn >> 12) & 255) << 12)
            immediate |= (((insn >> 20) & 1) << 11) | (((insn >> 21) & 1023) << 1)
            value, next_pc = pc + 4, (pc + signed(immediate, 21)) & MASK
        elif opcode == 0x67:
            if funct3 != 0:
                illegal()
            value, next_pc = pc + 4, ((a + imm_i) & MASK) & ~1
        elif opcode == 0x63:
            immediate = ((insn >> 31) << 12) | (((insn >> 7) & 1) << 11)
            immediate |= (((insn >> 25) & 63) << 5) | (((insn >> 8) & 15) << 1)
            conditions = {0: a == b, 1: a != b, 4: signed(a) < signed(b),
                          5: signed(a) >= signed(b), 6: a < b, 7: a >= b}
            if funct3 not in conditions:
                illegal()
            if conditions[funct3]:
                next_pc = (pc + signed(immediate, 13)) & MASK
        elif opcode == 0x03:
            sizes = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}
            if funct3 not in sizes:
                illegal()
            effective = (a + imm_i) & MASK
            size = sizes[funct3]
            value = self.read(effective, size)
            if funct3 in (0, 1):
                value = signed(value, size * 8)
        elif opcode == 0x23:
            if funct3 not in (0, 1, 2):
                illegal()
            immediate = signed(((insn >> 25) << 5) | ((insn >> 7) & 31), 12)
            effective, size = (a + immediate) & MASK, 1 << funct3
            if effective % size:
                raise ArchitecturalFault(f"misaligned store at {effective:#x}")
            if effective == EXIT_ADDRESS and size == 4:
                self.result = b
            elif not 0 <= effective <= RAM_LIMIT - size:
                raise ArchitecturalFault(f"invalid store at {effective:#x}")
            else:
                for offset in range(size):
                    self.memory[effective + offset] = (b >> (offset * 8)) & 255
            store, address = 1, effective & ~3
            lane = effective & 3
            strobe = ((1 << size) - 1) << lane
            # WDATA's inactive byte lanes are architecturally irrelevant.
            data = ((b & ((1 << (size * 8)) - 1)) << (lane * 8)) & MASK
        elif opcode == 0x13:
            if funct3 == 0:
                value = a + imm_i
            elif funct3 == 2:
                value = int(signed(a) < imm_i)
            elif funct3 == 3:
                value = int(a < (imm_i & MASK))
            elif funct3 == 4:
                value = a ^ (imm_i & MASK)
            elif funct3 == 6:
                value = a | (imm_i & MASK)
            elif funct3 == 7:
                value = a & (imm_i & MASK)
            elif funct3 == 1 and funct7 == 0:
                value = a << rs2
            elif funct3 == 5 and funct7 in (0, 0x20):
                value = (signed(a) if funct7 == 0x20 else a) >> rs2
            else:
                illegal()
        elif opcode == 0x33:
            if funct7 == 1:
                if funct3 == 0:
                    value = a * b
                elif funct3 == 1:
                    value = (signed(a) * signed(b)) >> 32
                elif funct3 == 2:
                    value = (signed(a) * b) >> 32
                elif funct3 == 3:
                    value = (a * b) >> 32
                elif funct3 in (4, 6):
                    dividend, divisor = signed(a), signed(b)
                    if divisor == 0:
                        quotient, remainder = -1, dividend
                    else:
                        quotient = abs(dividend) // abs(divisor)
                        if (dividend < 0) != (divisor < 0):
                            quotient = -quotient
                        remainder = dividend - quotient * divisor
                    value = quotient if funct3 == 4 else remainder
                elif funct3 == 5:
                    value = a // b if b else MASK
                else:
                    value = a % b if b else a
            elif funct7 == 0 or (funct7 == 0x20 and funct3 in (0, 5)):
                shift = b & 31
                values = {0: a - b if funct7 else a + b, 1: a << shift,
                          2: int(signed(a) < signed(b)), 3: int(a < b),
                          4: a ^ b, 5: (signed(a) if funct7 else a) >> shift,
                          6: a | b, 7: a & b}
                value = values[funct3]
            else:
                illegal()
        else:
            illegal()

        # A malformed jump is an architectural fault even when rd is x0.
        if next_pc & 3:
            raise ArchitecturalFault(f"misaligned next PC {next_pc:#x} at {pc:#x}")
        actual_rd = rd if value is not None and rd else 0
        actual_value = value & MASK if actual_rd else 0
        if actual_rd:
            self.regs[actual_rd] = actual_value
        event = Commit(self.retired, pc, insn, actual_rd, actual_value,
                       store, address, data, strobe)
        self.pc = next_pc
        self.retired += 1
        return event

    def run(self, max_instructions: int = 10_000_000) -> Iterator[Commit]:
        while self.result is None:
            if self.retired >= max_instructions:
                raise ArchitecturalFault(f"instruction limit {max_instructions} exceeded")
            yield self.step()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--max-instructions", type=int, default=10_000_000)
    args = parser.parse_args()
    machine = RV32.from_image(args.image)
    trace = args.trace.open("w") if args.trace else None
    try:
        for event in machine.run(args.max_instructions):
            if trace:
                trace.write(json.dumps(asdict(event)) + "\n")
    finally:
        if trace:
            trace.close()
    print(json.dumps({"result": machine.result, "dynamic_instructions": machine.retired}))


if __name__ == "__main__":
    main()
