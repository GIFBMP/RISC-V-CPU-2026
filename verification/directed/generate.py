#!/usr/bin/env python3
"""Generate reproducible RV32IM tests without an assembler or compiler."""
from __future__ import annotations

import argparse
from dataclasses import asdict
import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runners"))
from rv32_reference import RV32, MASK

R_OPS = {"add": (0, 0), "sub": (0, 32), "sll": (1, 0), "slt": (2, 0),
         "sltu": (3, 0), "xor": (4, 0), "srl": (5, 0), "sra": (5, 32),
         "or": (6, 0), "and": (7, 0), "mul": (0, 1), "mulh": (1, 1),
         "mulhsu": (2, 1), "mulhu": (3, 1), "div": (4, 1), "divu": (5, 1),
         "rem": (6, 1), "remu": (7, 1)}
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
B_OPS = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
L_OPS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
S_OPS = {"sb": 0, "sh": 1, "sw": 2}


class Program:
    def __init__(self, name: str, description: str):
        self.name, self.description = name, description
        self.words: list[int] = []
        self.source: list[str] = []
        self.labels: dict[str, int] = {}
        self.fixups: list[tuple[int, str, tuple]] = []
        self.data: dict[int, int] = {}
        self.probes: list[dict] = []
        self.speculation: list[dict] = []
        self.prediction: list[dict] = []
        self.pipeline: dict = {}
        self.li(28, 0x12345678)
        self.li(31, 0x10000)

    @property
    def pc(self) -> int:
        return len(self.words) * 4

    def emit(self, word: int, text: str) -> None:
        self.source.append(f"    {text:<34} # {self.pc:08x}: {word & MASK:08x}")
        self.words.append(word & MASK)

    def label(self, name: str) -> None:
        if name in self.labels:
            raise ValueError(f"duplicate label {name}")
        self.labels[name] = self.pc
        self.source.append(f"{name}:")

    def r(self, op: str, rd: int, rs1: int, rs2: int) -> None:
        f3, f7 = R_OPS[op]
        self.emit((f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33,
                  f"{op} x{rd}, x{rs1}, x{rs2}")

    def i(self, op: str, rd: int, rs1: int, immediate: int) -> None:
        if op in ("slli", "srli", "srai"):
            if not 0 <= immediate <= 31:
                raise ValueError("shift immediate out of range")
            f3 = 1 if op == "slli" else 5
            encoded = immediate | (0x400 if op == "srai" else 0)
        else:
            if not -2048 <= immediate <= 2047:
                raise ValueError("immediate out of range")
            f3, encoded = I_OPS[op], immediate & 0xFFF
        self.emit((encoded << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13,
                  f"{op} x{rd}, x{rs1}, {immediate}")

    def li(self, rd: int, value: int) -> None:
        value &= MASK
        low = (value & 0xFFF) - (0x1000 if value & 0x800 else 0)
        high = ((value - low) >> 12) & 0xFFFFF
        self.emit((high << 12) | (rd << 7) | 0x37, f"lui x{rd}, 0x{high:x}")
        self.i("addi", rd, rd, low)

    def load(self, op: str, rd: int, base: int, offset: int = 0) -> None:
        assert -2048 <= offset <= 2047
        self.emit(((offset & 0xFFF) << 20) | (base << 15) | (L_OPS[op] << 12) | (rd << 7) | 3,
                  f"{op} x{rd}, {offset}(x{base})")

    def store(self, op: str, rs: int, base: int, offset: int = 0) -> None:
        assert -2048 <= offset <= 2047
        imm = offset & 0xFFF
        self.emit(((imm >> 5) << 25) | (rs << 20) | (base << 15) | (S_OPS[op] << 12)
                  | ((imm & 31) << 7) | 0x23, f"{op} x{rs}, {offset}(x{base})")

    def branch(self, op: str, a: int, b: int, label: str) -> None:
        self.fixups.append((len(self.words), "branch", (op, a, b, label)))
        self.emit(0, f"{op} x{a}, x{b}, {label}")

    def jal(self, rd: int, label: str) -> None:
        self.fixups.append((len(self.words), "jal", (rd, label)))
        self.emit(0, f"jal x{rd}, {label}")

    def address(self, rd: int, label: str, offset: int = 0) -> None:
        self.fixups.append((len(self.words), "address", (rd, label, offset)))
        self.emit(0, f"lui x{rd}, %hi({label}{offset:+d})")
        self.emit(0, f"addi x{rd}, x{rd}, %lo({label}{offset:+d})")

    def jalr(self, rd: int, base: int, offset: int = 0) -> None:
        self.emit(((offset & 0xFFF) << 20) | (base << 15) | (rd << 7) | 0x67,
                  f"jalr x{rd}, {offset}(x{base})")

    def checksum(self, reg: int) -> None:
        self.r("xor", 28, 28, reg)
        self.i("addi", 28, 28, 17)
        self.i("slli", 29, 28, 5)
        self.r("xor", 28, 28, 29)

    def finish(self) -> None:
        self.li(30, 0x80000000)
        self.store("sw", 28, 30)
        self.label("halt")
        self.jal(0, "halt")

    def resolve(self) -> dict[int, int]:
        for index, kind, args in self.fixups:
            pc = index * 4
            if kind == "branch":
                op, a, b, label = args
                delta = self.labels[label] - pc
                assert delta % 2 == 0 and -4096 <= delta <= 4094
                imm = delta & 0x1FFF
                self.words[index] = ((imm >> 12) << 31) | (((imm >> 5) & 63) << 25)
                self.words[index] |= (b << 20) | (a << 15) | (B_OPS[op] << 12)
                self.words[index] |= (((imm >> 1) & 15) << 8) | (((imm >> 11) & 1) << 7) | 0x63
            elif kind == "jal":
                rd, label = args
                delta = self.labels[label] - pc
                assert delta % 2 == 0 and -(1 << 20) <= delta < (1 << 20)
                imm = delta & 0x1FFFFF
                self.words[index] = ((imm >> 20) << 31) | (((imm >> 1) & 1023) << 21)
                self.words[index] |= (((imm >> 11) & 1) << 20) | (((imm >> 12) & 255) << 12) | (rd << 7) | 0x6F
            else:
                rd, label, offset = args
                value = self.labels[label] + offset
                low = (value & 4095) - (4096 if value & 2048 else 0)
                self.words[index] = (((value - low) & 0xFFFFF000) | (rd << 7) | 0x37)
                self.words[index + 1] = ((low & 4095) << 20) | (rd << 15) | (rd << 7) | 0x13
        memory = dict(self.data)
        for index, word in enumerate(self.words):
            for lane in range(4):
                memory[index * 4 + lane] = (word >> (lane * 8)) & 255
        return memory


def integer_isa() -> Program:
    p = Program("integer_isa", "All RV32I integer ALU instructions, x0, shift masking and comparisons")
    for value in (0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x87654321):
        p.li(1, value)
        for shift in (0, 1, 31, 32, 63, 0xFFFFFFFF):
            p.li(2, shift)
            for op in tuple(R_OPS)[:10]:
                p.r(op, 3, 1, 2)
                p.checksum(3)
        for immediate in (-2048, -1, 0, 1, 2047):
            for op in I_OPS:
                p.i(op, 3, 1, immediate)
                p.checksum(3)
        for amount in (0, 1, 31):
            for op in ("slli", "srli", "srai"):
                p.i(op, 3, 1, amount)
                p.checksum(3)
    p.i("addi", 0, 1, 7)
    p.r("add", 3, 0, 0)
    p.checksum(3)
    p.emit(0x12345197, "auipc x3, 0x12345")
    p.checksum(3)
    p.finish()
    return p


def memory_lanes() -> Program:
    p = Program("memory_lanes", "All byte/halfword lanes, sign extension, overlap, negative offsets, x0 loads")
    p.li(1, 0x80FF7F01)
    p.store("sw", 1, 31)
    for offset in range(4):
        for op in ("lb", "lbu"):
            p.load(op, 3, 31, offset)
            p.checksum(3)
    for offset in (0, 2):
        for op in ("lh", "lhu"):
            p.load(op, 3, 31, offset)
            p.checksum(3)
    for lane in range(4):
        p.li(2, 0xFFFFFF80 + lane)
        p.store("sb", 2, 31, lane)
        p.load("lw", 3, 31)
        p.checksum(3)
    for offset in (0, 2):
        p.li(2, 0xABCD8001 + offset)
        p.store("sh", 2, 31, offset)
        p.load("lw", 3, 31)
        p.checksum(3)
    p.i("addi", 4, 31, 16)
    p.store("sw", 1, 4, -12)
    p.load("lw", 3, 4, -12)
    p.checksum(3)
    p.load("lw", 0, 31)
    p.load("lw", 3, 31, 256)
    p.checksum(3)
    p.finish()
    return p


def multiply_divide() -> Program:
    p = Program("m_extension", "All eight M instructions with divide-by-zero, overflow and signed high products")
    edges = (0, 1, 2, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFE, 0xFFFFFFFF)
    for a in edges:
        p.li(1, a)
        for b in edges:
            p.li(2, b)
            for op in tuple(R_OPS)[10:]:
                p.r(op, 3, 1, 2)
                p.checksum(3)
    p.r("div", 0, 1, 0)
    p.r("mulhu", 0, 1, 2)
    p.finish()
    return p


def dependencies() -> Program:
    p = Program("dependencies_wrap", "RAW/WAW/WAR, same-register operands and repeated queue wraparound")
    p.li(1, 0x7FFFFFFF)
    p.li(2, 7)
    for iteration in range(96):
        p.r("div", 3, 1, 2)
        p.r("add", 4, 3, 1)
        p.i("addi", 3, 0, iteration)
        p.i("addi", 1, 4, -17)
        p.r("xor", 4, 4, 3)
        p.r("add", 4, 4, 4)
        p.store("sw", 4, 31, (iteration % 16) * 4)
        p.load("lw", 5, 31, (iteration % 16) * 4)
        p.checksum(5)
    p.finish()
    return p


def out_of_order(kind: str) -> Program:
    p = Program(f"ooo_{kind}", "Require an independent young ADD to issue before an older dependent ADD")
    p.li(1, 0x71234567)
    p.li(2, 7)
    p.li(7, 99)
    if kind == "load":
        p.li(6, 0x18000)
        for lane, byte in enumerate((0x67, 0x45, 0x23, 0x71)):
            p.data[0x18000 + lane] = byte
    # Warm the instruction-cache line containing the measured triplet before
    # starting the long operation, so an I-cache miss cannot hide the OoO case.
    p.li(8, 1)
    p.jal(0, "warm_entry")
    while p.pc % 16:
        p.i("addi", 0, 0, 0)
    p.label("setup_done")
    p.label("producer")
    if kind == "mdu":
        p.r("div", 3, 1, 2)
    else:
        p.label("load_producer")
        p.load("lw", 3, 6)
    p.label("dependent")
    p.r("add", 4, 3, 7)
    p.label("independent")
    p.r("add", 5, 7, 7)
    p.label("warm_entry")
    p.branch("beq", 8, 0, "done")
    p.i("addi", 8, 8, -1)
    p.jal(0, "setup_done")
    p.label("done")
    p.checksum(4)
    p.checksum(5)
    p.finish()
    p.probes.append({"kind": "issue_reordering", "older": "dependent", "younger": "independent",
                     "producer": "producer" if kind == "mdu" else "load_producer"})
    return p


def wrong_path(kind: str) -> Program:
    p = Program(f"flush_{kind}", f"Prewarmed taken branch squashes a dispatched/issued younger {kind}")
    p.li(1, 0xF0000000 if kind in ("bad_load", "writeback_load") else 0x18000 if kind == "load" else 0x70000000)
    p.li(2, 1)
    p.li(5, 0x80000000)
    p.li(6, 0x18000)
    p.li(7, 0xBAD)
    p.li(8, 1)
    if kind == "dirty_store":
        # Establish a cached line with an architecturally committed write before
        # the wrong-path partial Store. A WB implementation must not dirty or
        # alter this line speculatively, even if it could respond immediately.
        p.li(11, 0x76543210)
        p.store("sw", 11, 31)
        p.load("lw", 12, 31)
    elif kind == "writeback_load":
        # An uncached wrong-path Load forces dirty draining independently of
        # cache associativity. The fault harness rejects the second WB word
        # once; after cancellation, final MMIO must retry the entire line.
        for offset in (0, 4, 8, 12):
            p.li(11, 0x76543210 + offset)
            p.store("sw", 11, 31, offset)
    for lane, byte in enumerate((0x78, 0x56, 0x34, 0x12)):
        p.data[0x18000 + lane] = byte
    # Warm the recovery line first, then the critical line. Jumping into each
    # line's final instruction avoids executing the intentional wrong path.
    p.jal(0, "warm_safe")
    while p.pc % 16:
        p.i("addi", 0, 0, 0)
    p.label("producer")
    if kind == "mdu":
        p.load("lw", 3, 6)
    else:
        p.r("divu", 3, 1, 2)
    p.label("branch")
    p.branch("beq", 0, 0, "safe")
    p.label("wrong_path")
    if kind == "store":
        p.store("sw", 7, 31)
    elif kind == "dirty_store":
        p.store("sb", 7, 31, 1)
    elif kind == "mmio":
        p.store("sw", 7, 5)
    elif kind == "illegal":
        p.emit(0xFFFFFFFF, ".word 0xffffffff")
    elif kind in ("bad_load", "load", "writeback_load"):
        # The branch is already done, but cannot retire before producer. The
        # load wakes up as producer retires and is killed on the next cycle.
        p.load("lw", 7, 3)
    else:
        p.r("div", 7, 3, 2)
    p.label("warm_tail")
    p.jal(0, "warm_back")
    p.label("safe")
    # Keep the first recovery allocation unretired so it cannot recycle a
    # smaller physical register before x7 reuses the killed Load's destination.
    if kind in ("load", "writeback_load"):
        p.r("divu", 9, 1, 2)
    else:
        p.i("addi", 9, 0, 0x456)
    p.label("replacement")
    p.i("addi", 7, 0, 0x123)
    p.i("addi", 10, 0, 0x789)
    p.label("warm_safe")
    p.branch("bne", 8, 0, "warm_tail")
    p.load("lw", 4, 31)
    p.checksum(4)
    p.checksum(3)
    p.checksum(7)
    p.checksum(9)
    p.finish()
    p.label("warm_back")
    p.i("addi", 8, 0, 0)
    p.jal(0, "producer")
    p.speculation.append({"kind": kind, "branch": "branch", "wrong": "wrong_path", "replacement": "replacement",
                          "require_reuse": kind == "load"})
    return p


def jumps_branches() -> Program:
    p = Program("jumps_branches", "Every signed/unsigned branch, taken/untaken, backward loops and JAL/JALR links")
    pairs = ((0, 0), (0, 1), (1, 0), (0xFFFFFFFF, 0), (0x80000000, 0x7FFFFFFF))
    serial = 0
    for a, b in pairs:
        p.li(1, a)
        p.li(2, b)
        for op in B_OPS:
            target = f"target_{serial}"
            p.branch(op, 1, 2, target)
            p.i("addi", 28, 28, 3)
            p.label(target)
            p.i("addi", 28, 28, 7)
            serial += 1
    p.li(1, 41)
    p.label("backward")
    p.i("addi", 1, 1, -1)
    p.i("addi", 28, 28, 1)
    p.branch("bne", 1, 0, "backward")
    p.jal(10, "function")
    p.label("return_here")
    p.checksum(10)
    p.checksum(11)
    p.address(12, "indirect", 1)  # JALR must clear bit zero.
    p.jalr(12, 12)  # rd == rs1 must use the old source value.
    p.emit(0xFFFFFFFF, ".word 0xffffffff")
    p.label("indirect")
    p.checksum(12)
    p.finish()
    p.label("function")
    p.i("addi", 11, 10, 9)
    p.jalr(0, 10)
    return p


def prediction_loop_exit() -> Program:
    p = Program("prediction_loop_exit", "Train a taken loop branch, then recover from a predicted-taken final fallthrough")
    p.li(1, 9)
    p.label("loop")
    p.i("addi", 1, 1, -1)
    p.i("addi", 28, 28, 13)
    p.label("predicted_branch")
    p.branch("bne", 1, 0, "loop")
    p.label("fallthrough")
    p.checksum(1)
    p.finish()
    p.prediction.append({"site": "predicted_branch", "targets": ["loop"] * 8 + ["fallthrough"],
                         "required_flushes": [0, 8], "minimum_correct": 4})
    return p


def prediction_jalr_switch() -> Program:
    p = Program("prediction_jalr_switch", "One JALR alternates trained targets while preserving each link result")
    p.li(1, 0)
    p.li(2, 6)
    p.li(3, 3)
    p.address(6, "target_a")
    p.label("indirect_call")
    p.jalr(10, 6, 1)
    p.i("addi", 1, 1, 1)
    p.branch("blt", 1, 3, "again")
    p.address(6, "target_b")
    p.label("again")
    p.branch("blt", 1, 2, "indirect_call")
    p.checksum(10)
    p.finish()
    p.label("target_a")
    p.i("addi", 28, 28, 11)
    p.jalr(0, 10)
    p.label("target_b")
    p.i("addi", 28, 28, 29)
    p.jalr(0, 10)
    p.prediction.append({"site": "indirect_call", "targets": ["target_a"] * 3 + ["target_b"] * 3,
                         "required_flushes": [0, 3], "minimum_correct": 2})
    return p


def prediction_alias() -> Program:
    p = Program("prediction_btb_alias", "PCs separated by 256 bytes alias a 64-entry BTB without borrowing the wrong target")
    p.li(1, 0)
    p.li(2, 3)
    p.jal(0, "site_a")
    while p.pc < 0x100:
        p.i("addi", 0, 0, 0)
    p.label("site_a")
    p.jal(10, "after_a")
    while p.pc < 0x200:
        p.i("addi", 0, 0, 0)
    p.label("site_b")
    p.jal(11, "after_b")
    p.label("after_a")
    p.i("addi", 1, 1, 1)
    p.checksum(10)
    p.branch("blt", 1, 2, "site_a")
    p.branch("beq", 1, 2, "site_b")
    p.finish()
    p.label("after_b")
    p.checksum(11)
    p.jal(0, "site_a")
    p.prediction.append({"site": "site_a", "targets": ["after_a"] * 4,
                         "required_flushes": [0, 3], "minimum_correct": 1})
    return p


def pipeline_contention() -> Program:
    p = Program("pipeline_completion", "Warm-loop load/fast-MDU completion contends with registered EX and rename wakeup")
    p.li(1, 0x71234567)
    p.li(2, 24)
    p.li(6, 0x18000)
    for lane, byte in enumerate((0x98, 0xBA, 0xDC, 0xFE)):
        p.data[0x18000 + lane] = byte
    p.label("loop")
    # Division by zero returns quickly, while independent ordinary operations
    # are already occupying the registered execution slot.
    p.r("divu", 3, 1, 0)
    p.i("addi", 4, 1, 11)
    p.i("addi", 5, 1, 13)
    p.i("addi", 7, 4, 17)
    p.load("lw", 9, 6)
    p.i("addi", 10, 1, 19)
    p.i("addi", 11, 1, 23)
    p.i("addi", 13, 10, 29)
    p.i("addi", 14, 1, 31)
    p.i("addi", 15, 1, 37)
    p.i("addi", 16, 14, 41)
    p.checksum(3)
    p.checksum(7)
    p.checksum(9)
    p.checksum(13)
    p.checksum(16)
    p.i("addi", 2, 2, -1)
    p.branch("bne", 2, 0, "loop")
    p.finish()
    p.pipeline = {"wb_stall_sources": [1, 2], "rename_bypass": True}
    return p


def memory_order_wrap() -> Program:
    p = Program("memory_order_wrap", "Repeated stores and younger loads reuse circular ROB slots and clear older-store masks")
    p.li(1, 0x1234)
    p.li(2, 97)
    p.label("loop")
    p.i("addi", 1, 1, 37)
    p.store("sw", 1, 31, 0)
    p.load("lw", 3, 31, 0)
    p.i("addi", 4, 3, -9)
    p.store("sb", 4, 31, 1)
    p.load("lbu", 5, 31, 1)
    p.store("sw", 3, 31, 4)
    p.load("lw", 7, 31, 4)
    p.checksum(5)
    p.checksum(7)
    p.i("addi", 2, 2, -1)
    p.branch("bne", 2, 0, "loop")
    p.finish()
    return p


def cache_conflict_dirty() -> Program:
    p = Program("cache_conflict_dirty", "Seven congruent lines, dirty replacement, partial writes and refetch preserve every byte")
    addresses = [0x20000 + index * 0x1000 for index in range(7)]
    for index, address in enumerate(addresses):
        for offset in range(64):
            p.data[address + offset] = (index * 41 + offset * 13 + 7) & 255
    for round_index in range(5):
        for index, address in enumerate(addresses):
            p.li(1, address)
            p.load("lw", 2, 1, 0)
            p.checksum(2)
            p.li(3, 0x81020304 ^ (round_index << 16) ^ (index * 0x01010101))
            p.store("sw", 3, 1, 4 * (round_index % 4))
            p.store("sb", 3, 1, 1)
            p.store("sh", 3, 1, 10)
            # Same-line hit following each Store must observe the newest bytes.
            for offset in (0, 4, 8, 12):
                p.load("lw", 4, 1, offset)
                p.checksum(4)
        # Reverse traversal combines recently resident hits and dirty victims.
        for address in reversed(addresses):
            p.li(1, address)
            for offset in (0, 4, 8, 12):
                p.load("lw", 4, 1, offset)
                p.checksum(4)
    p.finish()
    return p


def cache_partial_allocate() -> Program:
    p = Program("cache_partial_allocate", "Cold SB/SH allocate without losing untouched bytes; conflicting dirty lines reload accurately")
    for index in range(6):
        address = 0x30000 + index * 0x1000
        for offset in range(64):
            p.data[address + offset] = (0xA5 + 17 * index + 3 * offset) & 255
        p.li(1, address)
        p.li(2, 0xFEDCBA80 + index)
        # The very first access is a partial write miss.
        p.store("sb", 2, 1, 1)
        p.load("lw", 3, 1, 0)
        p.checksum(3)
        p.store("sh", 2, 1, 6)
        p.load("lw", 3, 1, 4)
        p.checksum(3)
        p.store("sw", 2, 1, 12)
    for index in range(6):
        p.li(1, 0x30000 + index * 0x1000)
        for offset in range(16):
            p.load("lbu", 3, 1, offset)
            p.checksum(3)
    p.finish()
    return p


def cache_exit_dirty() -> Program:
    p = Program("cache_exit_dirty", "Populate 256 dirty lines and exit immediately after final updates; external drain is checked by the memory unit bench")
    p.li(1, 0x40000)
    p.li(2, 256)
    p.li(3, 0xABCDEF01)
    p.label("dirty_loop")
    p.store("sw", 3, 1)
    p.store("sb", 2, 1, 5)
    p.store("sh", 3, 1, 10)
    p.load("lw", 4, 1)
    p.checksum(4)
    p.i("addi", 3, 3, 71)
    p.store("sw", 3, 1, 12)
    p.i("addi", 1, 1, 16)
    p.i("addi", 2, 2, -1)
    p.branch("bne", 2, 0, "dirty_loop")
    p.finish()
    return p


def random_program(seed: int, count: int) -> Program:
    rng = random.Random(seed)
    p = Program(f"random_{seed:08x}", f"Seed {seed}, {count} random arithmetic/memory/control operations")
    for reg in range(1, 16):
        p.li(reg, rng.getrandbits(32))
    for offset in range(256):
        p.data[0x10000 + offset] = rng.randrange(256)
    for index in range(count):
        rd, a, b = (rng.randrange(1, 16) for _ in range(3))
        choice = rng.randrange(10)
        if choice < 4:
            p.r(rng.choice(tuple(R_OPS)), rd, a, b)
        elif choice < 6:
            p.i(rng.choice(tuple(I_OPS)), rd, a, rng.randrange(-2048, 2048))
        elif choice == 6:
            op = rng.choice(tuple(L_OPS))
            size = 4 if op == "lw" else 2 if op in ("lh", "lhu") else 1
            p.load(op, rd, 31, rng.randrange(256 // size) * size)
        elif choice == 7:
            op = rng.choice(tuple(S_OPS))
            size = 1 << S_OPS[op]
            p.store(op, a, 31, rng.randrange(256 // size) * size)
        elif choice == 8:
            p.i(rng.choice(("slli", "srli", "srai")), rd, a, rng.randrange(32))
        else:
            label = f"skip_{index}"
            p.branch(rng.choice(tuple(B_OPS)), a, b, label)
            p.r("xor", rd, a, b)
            p.label(label)
        p.checksum(rd)
    for reg in range(1, 16):
        p.checksum(reg)
    p.finish()
    return p


def save(program: Program, output: Path) -> dict:
    memory = program.resolve()
    machine = RV32(memory)
    events = list(machine.run())
    folder = output / program.name
    folder.mkdir(parents=True, exist_ok=True)
    lines = ["# Generated by verification/directed/generate.py; sparse byte image."]
    previous = -2
    chunk: list[str] = []
    for address, value in sorted(memory.items()):
        if address != previous + 1:
            if chunk:
                lines.append(" ".join(chunk))
                chunk = []
            lines.append(f"@{address:08x}")
        chunk.append(f"{value:02x}")
        if len(chunk) == 16:
            lines.append(" ".join(chunk))
            chunk = []
        previous = address
    if chunk:
        lines.append(" ".join(chunk))
    (folder / "program.data").write_text("\n".join(lines) + "\n")
    # The text is assembly plus a separate resolved word listing. Symbolic
    # fixup comments intentionally do not claim to be final machine encodings.
    source = ["# " + program.description, ".option norvc", ".section .text", ".globl _start", "_start:"]
    source.extend(line.split(" # ", 1)[0] for line in program.source)
    (folder / "program.S").write_text("\n".join(source) + "\n")
    (folder / "program.words").write_text("".join(f"{i * 4:08x}: {w:08x}\n" for i, w in enumerate(program.words)))
    (folder / "expected.txt").write_text(f"{machine.result}\n")
    (folder / "metrics.json").write_text(json.dumps({"dynamic_instructions": machine.retired}, indent=2) + "\n")
    with (folder / "reference.jsonl").open("w") as trace:
        for event in events:
            trace.write(json.dumps(asdict(event), separators=(",", ":")) + "\n")
    probes = [{**probe, **{key + "_pc": program.labels[probe[key]]
                          for key in ("older", "younger", "producer")}} for probe in program.probes]
    metadata = {"name": program.name, "description": program.description, "labels": program.labels,
                "probes": probes, "result": machine.result, "dynamic_instructions": machine.retired}
    metadata["speculation"] = [{**probe, **{key + "_pc": program.labels[probe[key]]
                              for key in ("branch", "wrong", "replacement")}}
                              for probe in program.speculation]
    metadata["prediction"] = [{**probe, "site_pc": program.labels[probe["site"]],
                                "target_pcs": [program.labels[target] for target in probe["targets"]]}
                               for probe in program.prediction]
    metadata["pipeline"] = program.pipeline
    (folder / "meta.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build/verification/cases"))
    parser.add_argument("--seeds", default="1,7,23,42,99,256,1024,65535")
    parser.add_argument("--random-count", type=int, default=250)
    parser.add_argument("--case", help="generate only one named case")
    args = parser.parse_args()
    programs = [integer_isa(), memory_lanes(), multiply_divide(), dependencies(), jumps_branches(),
                out_of_order("mdu"), out_of_order("load")]
    programs += [wrong_path(kind) for kind in ("store", "mmio", "illegal", "bad_load", "load", "mdu")]
    programs += [prediction_loop_exit(), prediction_jalr_switch(), prediction_alias(),
                 pipeline_contention(), memory_order_wrap()]
    programs += [cache_conflict_dirty(), cache_partial_allocate(), cache_exit_dirty(),
                 wrong_path("dirty_store"), wrong_path("writeback_load")]
    programs += [random_program(int(seed, 0), args.random_count) for seed in args.seeds.split(",") if seed]
    if args.case:
        programs = [p for p in programs if p.name == args.case]
        if not programs:
            parser.error(f"unknown case {args.case}")
    for program in programs:
        result = save(program, args.out)
        print(f"{program.name:<24} instructions={result['dynamic_instructions']:>6} expected={result['result']}")


if __name__ == "__main__":
    main()
