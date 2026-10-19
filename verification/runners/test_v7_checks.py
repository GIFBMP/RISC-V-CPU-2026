from copy import deepcopy
import unittest

from run_cpu import parse_trace
from v7_checks import check_v7_invariants, check_v7_probe


def event(kind, identity, cycle, **fields):
    return kind, {"id": identity, "cycle": cycle, "pc": identity * 4, **fields}


def configuration():
    return event("CONFIG", 0, 0, version=7, select_width=2, rename_width=2, commit_width=2)


def late_store():
    return [configuration(),
            event("DISPATCH", 1, 0, insn=0x020040b3, rd=1, pdst=33),
            event("DISPATCH", 2, 0, insn=0x00102023, rd=0, pdst=0),
            event("DISPATCH", 3, 1, insn=0x00002283, rd=5, pdst=34),
            event("SELECT", 1, 1, insn=0x020040b3, lane=0, fast=0),
            event("SELECT", 2, 2, insn=0x00102023, lane=0, fast=0),
            event("ISSUE", 1, 2), event("ISSUE", 2, 3),
            event("STORE_ADDR", 2, 3, addr=0x10000, strb=15, psrc=33, ready=0),
            event("SELECT", 3, 4, insn=0x00002283, lane=0, fast=0),
            event("LOAD_RETRY", 3, 5), event("COMPLETE", 1, 5),
            event("STORE_DATA", 2, 5, data=0x12345678, psrc=33, late=1),
            event("SELECT", 3, 6, insn=0x00002283, lane=0, fast=1),
            event("ISSUE", 3, 6),
            event("LOAD_QUEUE", 3, 6, addr=0x10000, mask=15, data=0x12345678),
            event("COMMIT", 1, 6, store=0),
            event("COMMIT", 2, 6, store=1, addr=0x10000, data=0x12345678, strb=15),
            event("STORE_RETIRE", 2, 6), event("COMPLETE", 3, 7), event("COMMIT", 3, 8, store=0)]


class V7ChecksTests(unittest.TestCase):
    def test_late_store_retry_and_same_cycle_retirement(self):
        error, proof = check_v7_invariants(late_store())
        self.assertIsNone(error)
        self.assertEqual(proof["late_store_data"], 1)
        self.assertEqual(proof["retries"], 1)

    def test_wrong_capture_or_forwarded_bytes_are_rejected(self):
        for kind in ("STORE_DATA", "LOAD_QUEUE", "COMMIT"):
            rows = late_store()
            row = next(f for k, f in rows if k == kind and "data" in f)
            row["data"] ^= 256
            self.assertIsNotNone(check_v7_invariants(rows)[0], kind)

    def test_wrong_source_or_missing_producer_completion_is_rejected(self):
        rows = late_store()
        next(f for k, f in rows if k == "STORE_DATA")["psrc"] = 35
        self.assertIsNotNone(check_v7_invariants(rows)[0])
        rows = [e for e in late_store() if not (e[0] == "COMPLETE" and e[1]["id"] == 1)]
        self.assertIsNotNone(check_v7_invariants(rows)[0])

    def test_retry_cannot_duplicate_execution_or_lose_its_retry_event(self):
        rows = late_store()
        rows.append(event("ISSUE", 3, 7))
        self.assertIsNotNone(check_v7_invariants(rows)[0])
        self.assertIsNotNone(check_v7_invariants([e for e in late_store() if e[0] != "LOAD_RETRY"])[0])

    def test_three_accepts_are_valid_but_three_selections_are_not(self):
        rows = [configuration(),
                event("DISPATCH", 1, 0, insn=0x13), event("DISPATCH", 2, 0, insn=0x13),
                event("DISPATCH", 3, 1, insn=0x2003),
                event("SELECT", 1, 1, insn=0x13, lane=0, fast=0),
                event("SELECT", 2, 1, insn=0x13, lane=1, fast=0),
                event("SELECT", 3, 2, insn=0x2003, lane=0, fast=1),
                *[event("ISSUE", i, 2) for i in (1, 2, 3)],
                event("LOAD_QUEUE", 3, 2, addr=0x10000, mask=0, data=0)]
        self.assertIsNone(check_v7_invariants(rows)[0])
        bad = deepcopy(rows)
        next(f for k, f in bad if k == "SELECT" and f["id"] == 3)["cycle"] = 1
        self.assertIsNotNone(check_v7_invariants(bad)[0])
        bad = deepcopy(rows)
        next(f for k, f in bad if k == "SELECT" and f["id"] == 2)["lane"] = 0
        self.assertIsNotNone(check_v7_invariants(bad)[0])

    def test_pairs_require_surviving_instructions(self):
        probe = {"kind": "pairs", "pairs": {"DISPATCH": ["integer+control"]}}
        rows = [event("DISPATCH", 1, 0, insn=0x13), event("DISPATCH", 2, 0, insn=0x67),
                event("COMMIT", 1, 5)]
        self.assertIsNotNone(check_v7_probe(probe, rows)[0])
        rows.append(event("COMMIT", 2, 6))
        self.assertIsNone(check_v7_probe(probe, rows)[0])

    def test_decimal_source_and_configuration_fields(self):
        self.assertEqual(parse_trace("CPU_TRACE STORE_ADDR id=2 cycle=4 pc=8 psrc=33 ready=0")[1]["psrc"], 33)
        self.assertEqual(parse_trace("CPU_TRACE CONFIG id=0 cycle=0 pc=0 checkpoints=8 version=7")[1]["version"], 7)

    def test_killed_store_probe_requires_actual_slot_reuse(self):
        probe = {"kind":"cancel_store_data", "store_pc":16, "branch_pc":12, "producer_pc":4}
        rows = [event("DISPATCH",4,1,slot=7), event("STORE_ADDR",4,3,ready=0),
                event("FLUSH",3,4), event("DISPATCH",5,5,slot=7),
                event("COMPLETE",1,8), event("COMMIT",1,9), event("COMMIT",3,10)]
        self.assertIsNone(check_v7_probe(probe, rows)[0])
        self.assertIsNotNone(check_v7_probe(probe, [e for e in rows if e[1]["id"] != 5])[0])
        self.assertIsNotNone(check_v7_probe(probe, rows + [event("STORE_DATA",4,8)])[0])

    def test_kept_execution_requires_old_live_identity_and_unique_completion(self):
        probe = {"kind": "keep_execution"}
        rows = [event("DISPATCH", 1, 1, insn=0x13), event("SELECT", 1, 2),
                event("EX_KEEP", 1, 4, insn=0x13), event("FLUSH", 3, 4, selective=1),
                event("ISSUE", 1, 5), event("COMPLETE", 1, 5), event("COMMIT", 1, 6)]
        self.assertIsNone(check_v7_probe(probe, rows)[0])
        for extra in (event("ISSUE", 1, 3), event("COMPLETE", 1, 7)):
            self.assertIsNotNone(check_v7_probe(probe, rows + [extra])[0])
        for missing in ("SELECT", "FLUSH", "COMMIT"):
            self.assertIsNotNone(check_v7_probe(probe, [e for e in rows if e[0] != missing])[0])
        young = deepcopy(rows)
        next(f for k, f in young if k == "FLUSH")["id"] = 0
        self.assertIsNotNone(check_v7_probe(probe, young)[0])


if __name__ == "__main__":
    unittest.main()
