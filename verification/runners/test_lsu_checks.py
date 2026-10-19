"""Negative controls for LSU evidence; a correct checksum alone cannot pass."""
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest

from analyze_dependencies import analyze
from lsu_checks import check_lsu, check_memory_transactions
from run_cpu import check_recovery, parse_trace


def event(kind, identity, cycle, pc=4, **fields):
    return kind, {"id": identity, "cycle": cycle, "pc": pc, **fields}


class MemoryEvidence(unittest.TestCase):
    def test_transaction_order_identity_and_killed_writeback(self):
        events = [event("MEM_REQUEST", 10, 1, write=0, addr=0x10000, killed=0),
                  event("MEM_REQUEST", 11, 2, write=0, addr=0x10004, killed=1),
                  event("MEM_RESPONSE", 10, 3, write=0, killed=0),
                  event("MEM_RESPONSE", 11, 4, write=0, killed=1), event("DROP_LOAD", 11, 4),
                  event("MEM_REQUEST", 12, 5, write=1, addr=0x80000000, killed=0)]
        error, proof = check_memory_transactions(events)
        self.assertIsNone(error)
        self.assertEqual(proof["maximum_accepted_outstanding"], 2)
        reordered = deepcopy(events)
        reordered[2][1]["id"] = 11
        self.assertIsNotNone(check_memory_transactions(reordered)[0])
        stale = events + [event("COMPLETE", 11, 4)]
        self.assertIsNotNone(check_memory_transactions(stale)[0])
        self.assertIsNotNone(check_memory_transactions(events[:-3] + events[-1:])[0])
        bad_pc = deepcopy(events)
        bad_pc[3][1]["pc"] = 8
        self.assertIsNotNone(check_memory_transactions(bad_pc)[0])

    def test_forwarding_requires_unretired_older_store_and_exact_mask(self):
        probe = {"kind": "forward", "load_pc": 8, "store_pcs": [4], "mask": 14}
        events = [event("DISPATCH", 1, 0), event("ISSUE", 1, 2),
                  event("DISPATCH", 2, 1, pc=8), event("LOAD_QUEUE", 2, 3, pc=8, mask=14),
                  event("COMMIT", 1, 8), event("COMMIT", 2, 9, pc=8)]
        self.assertIsNone(check_lsu(probe, events)[0])
        wrong_mask = deepcopy(events)
        wrong_mask[3][1]["mask"] = 15
        self.assertIsNotNone(check_lsu(probe, wrong_mask)[0])
        retired = deepcopy(events)
        retired[4][1]["cycle"] = 3
        self.assertIsNotNone(check_lsu(probe, retired)[0])

    def test_unknown_store_checker_checks_every_dynamic_occurrence(self):
        probe = {"kind": "unknown_store", "load_pc": 8, "store_pc": 4}
        events = [event("DISPATCH", 1, 0), event("DISPATCH", 2, 1, pc=8),
                  event("ISSUE", 1, 4), event("LOAD_QUEUE", 2, 5, pc=8), event("COMMIT", 2, 6, pc=8)]
        self.assertIsNone(check_lsu(probe, events)[0])
        events += [event("DISPATCH", 3, 10), event("DISPATCH", 4, 11, pc=8),
                   event("ISSUE", 3, 14), event("LOAD_QUEUE", 4, 13, pc=8), event("COMMIT", 4, 16, pc=8)]
        self.assertIsNotNone(check_lsu(probe, events)[0])

    def test_multiple_killed_loads_require_actual_acceptance_and_live_reuse(self):
        probe = {"kind": "kill_multiple", "branch_pc": 4, "load_pcs": [8, 12],
                 "replacement_pcs": [16], "minimum": 2, "minimum_accepted_at_flush": 2,
                 "require_reuse": True}
        events = [event("FLUSH", 5, 10),
                  event("DISPATCH", 6, 2, pc=8, pdst=33), event("LOAD_QUEUE", 6, 7, pc=8),
                  event("DISPATCH", 7, 3, pc=12, pdst=34), event("LOAD_QUEUE", 7, 8, pc=12),
                  event("MEM_REQUEST", 6, 8, pc=8), event("MEM_REQUEST", 7, 10, pc=12),
                  event("MEM_RESPONSE", 6, 20, pc=8, killed=1), event("DROP_LOAD", 6, 20, pc=8),
                  event("MEM_RESPONSE", 7, 21, pc=12, killed=1), event("DROP_LOAD", 7, 21, pc=12),
                  event("DISPATCH", 9, 13, pc=16, pdst=33), event("COMMIT", 9, 25, pc=16)]
        # Earlier warm-up occurrences at the same PCs must not be confused
        # with the wrong-path incarnations following this dynamic branch.
        events += [event("COMMIT", 1, 1, pc=8)]
        self.assertIsNone(check_lsu(probe, events)[0])
        late = deepcopy(events)
        late[6][1]["cycle"] = 11
        self.assertIsNotNone(check_lsu(probe, late)[0])
        no_live_reuse = [item for item in events if not (item[0] == "COMMIT" and item[1]["id"] == 9)]
        self.assertIsNotNone(check_lsu(probe, no_live_reuse)[0])
        self.assertIsNotNone(check_lsu(probe, events + [event("COMPLETE", 6, 20, pc=8)])[0])

    def test_queue_depth_decimal(self):
        self.assertEqual(parse_trace("CPU_TRACE LOAD_QUEUE id=3 cycle=4 pc=8 mask=e depth=10")[1]["depth"], 10)

    def test_younger_store_cannot_forward_or_commit_before_older_load(self):
        probe = {"kind": "younger_store", "load_pc": 8, "store_pc": 12}
        events = [event("DISPATCH", 2, 0, pc=8), event("DISPATCH", 3, 1, pc=12),
                  event("ISSUE", 3, 3, pc=12), event("LOAD_QUEUE", 2, 10, pc=8, mask=0),
                  event("COMMIT", 2, 20, pc=8), event("COMMIT", 3, 21, pc=12)]
        self.assertIsNone(check_lsu(probe, events)[0])
        simultaneous = deepcopy(events)
        simultaneous[5][1].update(cycle=20, seq=3)
        simultaneous[4][1]["seq"] = 2
        self.assertIsNone(check_lsu(probe, simultaneous)[0])
        simultaneous[5][1]["seq"] = 1
        self.assertIsNotNone(check_lsu(probe, simultaneous)[0])
        wrong = deepcopy(events)
        wrong[3][1]["mask"] = 15
        self.assertIsNotNone(check_lsu(probe, wrong)[0])
        wrong = deepcopy(events)
        wrong[5][1]["cycle"] = 19
        self.assertIsNotNone(check_lsu(probe, wrong)[0])

    def test_early_fetch_requires_actual_priority_events(self):
        probe = {"kind": "older_override", "older_pc": 4, "younger_pc": 8, "target_pc": 16}
        events = [event("EARLY_FETCH", 2, 3, pc=8, target=24, prev_id=0, override=0),
                  event("EARLY_FETCH", 1, 8, target=16, prev_id=2, override=1),
                  event("COMMIT", 1, 9), event("FLUSH", 1, 10, target=16, prepared=1)]
        self.assertIsNone(check_recovery(probe, events)[0])
        self.assertIsNotNone(check_recovery(probe, events + [event("COMMIT", 2, 11, pc=8)])[0])
        probe["kind"] = "commit_collision"
        events = [event("COMMIT", 1, 9), event("FLUSH", 1, 10, target=16, prepared=1),
                  event("EARLY_BLOCK", 2, 9, pc=8, head_id=1)]
        self.assertIsNone(check_recovery(probe, events)[0])
        self.assertIsNotNone(check_recovery(probe, events[:-1])[0])
        events.append(event("EARLY_FETCH", 2, 9, pc=8, target=24))
        self.assertIsNotNone(check_recovery(probe, events)[0])


class DependencyEvidence(unittest.TestCase):
    def test_source_identity_precedes_same_register_write_and_gap_partition(self):
        # ADDI x1,x0,1; ADDI x1,x1,1; ADD x2,x1,x0; BEQ x1,x0; BEQ x1,x1.
        instructions = [0x00100093, 0x00108093, 0x00008133, 0x00008063, 0x00108063]
        times = [(0, 3, 3, 4), (2, 4, 4, 5), (3, 5, 5, 8), (4, 7, 7, 9), (8, 10, 10, 11)]
        lines = []
        for identity, (insn, clock) in enumerate(zip(instructions, times), 1):
            for kind, cycle in zip(("DISPATCH", "ISSUE", "COMPLETE", "COMMIT"), clock):
                rd = (insn >> 7) & 31 if identity <= 3 else 0
                lines.append(f"CPU_TRACE {kind} id={identity} cycle={cycle} pc={(identity-1)*4:x} "
                             f"insn={insn:x} rd={rd} value={1 if identity == 1 else 2:x}")
        lines.append("CPU_TRACE FLUSH id=5 cycle=12 pc=10 target=10")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sim.log"
            path.write_text("\n".join(lines) + "\nPASS cycles=20 result=0 expected=0\n")
            report = analyze(path)
        self.assertEqual(report["ready_to_issue_when_already_dispatched"]["alu"]["count"], 3)
        self.assertEqual(report["ready_to_issue_when_already_dispatched"]["alu"]["minimum"], 1)
        self.assertEqual(sum(report["commit_gap_next_instruction_state"].values()), 3)
        self.assertEqual(report["ideal_committed_direction_errors"]["unaliased_bimodal"], 1)
        self.assertEqual(report["mispredict_issue_to_flush"]["mean"], 2)


if __name__ == "__main__":
    unittest.main()
