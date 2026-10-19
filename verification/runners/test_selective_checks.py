"""Negative controls for identity conservation and actual dual completion."""
from copy import deepcopy
import unittest

from run_cpu import check_pipeline, parse_trace
from selective_checks import check_selective_invariants, check_selective_probe


def e(kind, identity, cycle, **fields):
    return kind, {"id": identity, "cycle": cycle, "pc": 4 * identity, **fields}


class RecoveryEvidence(unittest.TestCase):
    def fixture(self):
        return [e("DISPATCH", 1, 0, slot=15), e("ISSUE", 1, 1),
                e("DISPATCH", 2, 1, slot=0), e("DISPATCH", 3, 2, slot=1),
                e("ISSUE", 2, 3), e("COMPLETE", 2, 3),
                e("FLUSH", 2, 4, selective=1, head_id=1, kept=2, killed=1),
                e("DISPATCH", 4, 5, slot=1), e("ISSUE", 4, 6), e("COMPLETE", 4, 6),
                e("COMPLETE", 1, 9), e("COMMIT", 1, 10, seq=0),
                e("COMMIT", 2, 11, seq=1), e("COMMIT", 4, 12, seq=2)]

    def test_wrap_conservation_and_reused_slot_does_not_revive_old_id(self):
        events = self.fixture()
        error, evidence = check_selective_invariants(events)
        self.assertIsNone(error)
        self.assertEqual(evidence["wrapped_preserved_windows"], 1)
        bad = events + [e("COMPLETE", 3, 8)]
        self.assertIsNotNone(check_selective_invariants(bad)[0])
        bad = deepcopy(events)
        bad[6][1]["kept"] = 1
        self.assertIsNotNone(check_selective_invariants(bad)[0])

    def test_store_architectural_trace_before_response_is_still_live_in_rob(self):
        events = [e("DISPATCH", 1, 0, slot=0), e("ISSUE", 1, 1),
                  e("COMMIT", 1, 2, store=1), e("DISPATCH", 2, 2, slot=1),
                  e("FLUSH", 2, 4, selective=1, head_id=1, kept=2, killed=0),
                  e("STORE_RETIRE", 1, 8), e("COMMIT", 2, 9)]
        self.assertIsNone(check_selective_invariants(events)[0])

    def test_old_mdu_recovery_requires_early_new_execution_and_no_restart(self):
        probe = {"kind": "selective_keep", "operation": "mdu", "older_pc": 4,
                 "branch_pc": 8, "target_pc": 16, "early_resume": True, "wrap": True}
        events = self.fixture()
        self.assertIsNone(check_selective_probe(probe, events)[0])
        late = deepcopy(events)
        late[8][1]["cycle"] = 10
        self.assertIsNotNone(check_selective_probe(probe, late)[0])
        self.assertIsNotNone(check_selective_probe(probe, events + [e("ISSUE", 1, 5)])[0])
        self.assertIsNotNone(check_selective_probe(probe, events + [e("DROP_MDU", 1, 4)])[0])

    def test_identity_and_slot_fields_are_decimal(self):
        fields = parse_trace("CPU_TRACE FLUSH id=10 cycle=20 pc=10 slot=15 selective=1 head_id=8 kept=10 killed=2")[1]
        self.assertEqual((fields["id"], fields["slot"], fields["kept"], fields["pc"]), (10, 15, 10, 16))

    def test_response_ready_on_recovery_requires_hold_then_unique_completion(self):
        probe = {"kind": "selective_hold", "source": 2, "older_pcs": [4]}
        events = self.fixture() + [e("RECOVERY_HOLD", 1, 4, source=2)]
        self.assertIsNone(check_selective_probe(probe, events)[0])
        self.assertIsNotNone(check_selective_probe(probe, self.fixture())[0])
        self.assertIsNotNone(check_selective_probe(probe, events + [e("DROP_MDU", 1, 4)])[0])

    def test_checkpoint_full_requires_all_four_allocated_and_fifth_delayed(self):
        probe = {"kind": "selective_checkpoint_full", "capacity": 4, "older_pc": 4,
                 "branch_pcs": [8, 12, 16, 20, 24]}
        events = [e("COMPLETE", 1, 20), e("COMMIT", 1, 21)]
        for identity in range(2, 7):
            events += [e("DISPATCH", identity, identity if identity < 6 else 23),
                       e("COMPLETE", identity, identity + 2 if identity < 6 else 25),
                       e("COMMIT", identity, identity + 20)]
        self.assertIsNone(check_selective_probe(probe, events)[0])
        for kind, fields in events:
            if kind == "DISPATCH" and fields["id"] == 6:
                fields["cycle"] = 10
        self.assertIsNotNone(check_selective_probe(probe, events)[0])


class ParallelCompletionEvidence(unittest.TestCase):
    def test_dual_mode_needs_two_real_unique_surviving_completions(self):
        events = [e("CONFIG", 0, 0, dual_wb=1), e("ISSUE", 1, 1), e("ISSUE", 2, 2),
                  e("COMPLETE", 1, 2, insn=0x2083), e("COMPLETE", 2, 2, insn=0x13),
                  e("MEM_RESPONSE", 1, 2, write=0, killed=0),
                  e("WB_PAIR", 2, 2, load_id=1, ex_id=2, memory=1),
                  e("COMMIT", 1, 3), e("COMMIT", 2, 4)]
        requirement = {"wb_stall_sources": [1]}
        self.assertIsNone(check_pipeline(requirement, events)[0])
        self.assertIsNotNone(check_pipeline(requirement, [x for x in events if x[0] != "MEM_RESPONSE"])[0])
        self.assertIsNotNone(check_pipeline(requirement, events + [e("COMPLETE", 2, 3)])[0])
        # An event claiming dual completion does not change the explicitly
        # configured hardware mode or silently bypass V4 stall evidence.
        self.assertIsNotNone(check_pipeline(requirement, events[1:])[0])


if __name__ == "__main__":
    unittest.main()
