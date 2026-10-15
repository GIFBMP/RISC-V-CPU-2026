#!/usr/bin/env python3
"""Oracle/trace checker unit tests with fixed ISA boundary answers."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rv32_reference import ArchitecturalFault, Commit, RV32
from run_cpu import check_ooo, check_pipeline, check_prediction, check_speculation, compare_commit, parse_trace


def one_instruction(word: int, a: int = 0, b: int = 0) -> tuple[RV32, Commit]:
    memory = {index: (word >> (8 * index)) & 255 for index in range(4)}
    cpu = RV32(memory)
    cpu.regs[1], cpu.regs[2] = a, b
    return cpu, cpu.step()


class ReferenceBoundaries(unittest.TestCase):
    def test_m_extension_fixed_answers(self):
        # Fixed encodings: OP M, rd=x3, rs1=x1, rs2=x2.
        examples = [
            (0x022081B3, 0xFFFFFFFF, 0xFFFFFFFF, 1),        # MUL
            (0x022091B3, 0xFFFFFFFF, 2, 0xFFFFFFFF),        # MULH
            (0x022091B3, 0x80000000, 0x80000000, 0x40000000),
            (0x0220A1B3, 0x80000000, 0xFFFFFFFF, 0x80000000),  # MULHSU
            (0x0220A1B3, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF),
            (0x0220B1B3, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFE),  # MULHU
            (0x0220C1B3, 0xFFFFFFF9, 3, 0xFFFFFFFE),       # DIV -7/3=-2
            (0x0220C1B3, 7, 0xFFFFFFFD, 0xFFFFFFFE),
            (0x0220C1B3, 0x80000000, 0xFFFFFFFF, 0x80000000),
            (0x0220C1B3, 0x80000000, 0, 0xFFFFFFFF),
            (0x0220D1B3, 0xFFFFFFFF, 2, 0x7FFFFFFF),       # DIVU
            (0x0220D1B3, 0, 0, 0xFFFFFFFF),
            (0x0220E1B3, 0xFFFFFFF9, 3, 0xFFFFFFFF),       # REM -7%3=-1
            (0x0220E1B3, 7, 0xFFFFFFFD, 1),
            (0x0220E1B3, 0x80000000, 0xFFFFFFFF, 0),
            (0x0220E1B3, 0x80000000, 0, 0x80000000),
            (0x0220F1B3, 0xFFFFFFFF, 2, 1),                # REMU
            (0x0220F1B3, 0xFFFFFFFF, 0, 0xFFFFFFFF),
        ]
        for insn, a, b, expected in examples:
            with self.subTest(insn=hex(insn), a=hex(a), b=hex(b)):
                cpu, event = one_instruction(insn, a, b)
                self.assertEqual(event.value, expected)
                self.assertEqual(cpu.regs[3], expected)

    def test_register_shift_masks_to_five_bits(self):
        _, event = one_instruction(0x002091B3, 0x12345678, 32)  # SLL x3,x1,x2
        self.assertEqual(event.value, 0x12345678)
        _, event = one_instruction(0x4020D1B3, 0x80000000, 63)  # SRA x3,x1,x2
        self.assertEqual(event.value, 0xFFFFFFFF)

    def test_x0_is_not_written(self):
        cpu, event = one_instruction(0xFFF00013)  # ADDI x0,x0,-1
        self.assertEqual((cpu.regs[0], event.rd, event.value), (0, 0, 0))

    def test_jalr_reads_source_before_writing_same_register(self):
        cpu, event = one_instruction(0x000080E7, 0x101)  # JALR x1,0(x1)
        self.assertEqual((cpu.pc, cpu.regs[1], event.value), (0x100, 4, 4))

    def test_byte_sign_extension_and_store_lanes(self):
        cpu = RV32({0: 0x83, 1: 0x81, 2: 0x10, 3: 0x00, 0x101: 0x80})  # LB x3,1(x1)
        cpu.regs[1] = 0x100
        self.assertEqual(cpu.step().value, 0xFFFFFF80)
        _, event = one_instruction(0x002081A3, 0x100, 0x12345680)  # SB x2,3(x1)
        self.assertEqual((event.addr, event.strb, event.data), (0x100, 8, 0x80000000))
        _, event = one_instruction(0x00209123, 0x100, 0x12348001)  # SH x2,2(x1)
        self.assertEqual((event.addr, event.strb, event.data), (0x100, 12, 0x80010000))

    def test_store_exit_is_final_commit(self):
        cpu, event = one_instruction(0x0020A023, 0x80000000, 0x12345678)
        self.assertEqual((cpu.result, event.store, event.data), (0x12345678, 1, 0x12345678))
        self.assertEqual(list(cpu.run()), [])

    def test_architectural_faults_are_not_silently_accepted(self):
        for insn in (0xFFFFFFFF, 0x02001013):  # Illegal opcode and invalid SLLI funct7.
            with self.assertRaises(ArchitecturalFault):
                one_instruction(insn)
        with self.assertRaises(ArchitecturalFault):
            one_instruction(0x0000A003, 0xF0000000)  # LW x0,0(x1) must still fault.


class TraceChecks(unittest.TestCase):
    def test_parsing_and_inactive_store_bytes(self):
        parsed = parse_trace("CPU_TRACE COMMIT seq=0 id=17 cycle=42 pc=00000000 insn=002081a3 rd=0 value=00000000 store=1 addr=00000100 data=80123456 strb=8\n")
        self.assertIsNotNone(parsed)
        expected = Commit(0, 0, 0x002081A3, store=1, addr=0x100, data=0x80000000, strb=8)
        self.assertIsNone(compare_commit(parsed[1], expected))
        parsed[1]["data"] ^= 0x01000000
        self.assertIn("data expected", compare_commit(parsed[1], expected))

    def test_ooo_requires_actual_issue_reordering_and_commit_identity(self):
        probe = {"older_pc": 4, "younger_pc": 8}
        events = [("ISSUE", {"pc": 8, "id": 3, "cycle": 10}),
                  ("ISSUE", {"pc": 4, "id": 2, "cycle": 20}),
                  ("COMMIT", {"pc": 4, "id": 2, "cycle": 21, "seq": 2}),
                  ("COMMIT", {"pc": 8, "id": 3, "cycle": 22, "seq": 3})]
        self.assertIsNone(check_ooo(probe, events)[0])
        events[0][1]["id"] = 99  # Squashed incarnation cannot be evidence.
        self.assertIsNotNone(check_ooo(probe, events)[0])
        events[0][1]["id"], events[0][1]["cycle"] = 3, 30
        self.assertIsNotNone(check_ooo(probe, events)[0])

    def test_flush_requires_inflight_drain_and_committed_reuse(self):
        probe = {"kind": "load", "branch_pc": 4, "wrong_pc": 8,
                 "replacement_pc": 16, "require_reuse": True}
        events = [("DISPATCH", {"pc": 8, "id": 3, "cycle": 5, "rd": 7, "pdst": 33}),
                  ("ISSUE", {"pc": 8, "id": 3, "cycle": 10}),
                  ("FLUSH", {"pc": 4, "id": 2, "cycle": 11, "load_pending": 1}),
                  ("DISPATCH", {"pc": 16, "id": 9, "cycle": 15, "rd": 7, "pdst": 33}),
                  ("COMMIT", {"pc": 16, "id": 9, "cycle": 20, "seq": 5}),
                  ("DROP_LOAD", {"pc": 8, "id": 3, "cycle": 30})]
        self.assertIsNone(check_speculation(probe, events)[0])
        self.assertIsNotNone(check_speculation(probe, events[:-1])[0])
        self.assertIsNotNone(check_speculation(probe, [event for event in events if event[0] != "COMMIT"])[0])
        completed = events + [("COMPLETE", {"pc": 8, "id": 3, "cycle": 10})]
        self.assertIsNotNone(check_speculation(probe, completed)[0])

    def test_physical_register_trace_fields_are_decimal(self):
        parsed = parse_trace("CPU_TRACE DISPATCH id=30 cycle=702 pc=00000064 insn=12300393 rd=7 pdst=33")
        self.assertEqual(parsed[1]["pdst"], 33)

    def test_prediction_requires_recovery_and_correctly_predicted_occurrences(self):
        probe = {"site_pc": 8, "target_pcs": [4, 4, 12], "required_flushes": [0, 2], "minimum_correct": 1}
        events = [("COMMIT", {"pc": 8, "id": 2}), ("FLUSH", {"pc": 8, "id": 2, "target": 4}),
                  ("COMMIT", {"pc": 8, "id": 7}), ("COMMIT", {"pc": 8, "id": 12}),
                  ("FLUSH", {"pc": 8, "id": 12, "target": 12})]
        self.assertIsNone(check_prediction(probe, events)[0])
        self.assertIsNotNone(check_prediction(probe, events[:-1])[0])
        self.assertIsNotNone(check_prediction(probe, events + [("FLUSH", {"pc": 8, "id": 7, "target": 4})])[0])

    def test_pipeline_requires_stall_then_single_execution_and_live_bypass(self):
        requirements = {"wb_stall_sources": [1, 2], "rename_bypass": True}
        events = [("WB_STALL", {"id": 1, "cycle": 4, "source": 1}),
                  ("ISSUE", {"id": 1, "cycle": 5}), ("COMPLETE", {"id": 1, "cycle": 5}),
                  ("COMMIT", {"id": 1, "cycle": 6}),
                  ("WB_STALL", {"id": 2, "cycle": 7, "source": 2}),
                  ("ISSUE", {"id": 2, "cycle": 8}), ("COMPLETE", {"id": 2, "cycle": 8}),
                  ("COMMIT", {"id": 2, "cycle": 9}),
                  ("RENAME_BYPASS", {"id": 1, "cycle": 2, "source": 3})]
        self.assertIsNone(check_pipeline(requirements, events)[0])
        self.assertIsNotNone(check_pipeline(requirements, events + [("ISSUE", {"id": 1, "cycle": 10})])[0])
        self.assertIsNotNone(check_pipeline(requirements, events[:-1])[0])


if __name__ == "__main__":
    unittest.main()
