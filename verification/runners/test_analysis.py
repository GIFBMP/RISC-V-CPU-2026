"""Guard the conservative interpretation of trace-derived stall metrics."""
from pathlib import Path
import tempfile
import unittest

from analyze_trace import analyze


class TraceAnalysis(unittest.TestCase):
    def test_buffered_store_uses_explicit_request_after_rob_retirement(self):
        lines = ["DISPATCH id=1 cycle=0 pc=0 insn=2023", "ISSUE id=1 cycle=1 pc=0 insn=2023",
                 "STORE_RETIRE id=1 cycle=2 pc=0",  # Textually precedes COMMIT on this edge.
                 "COMMIT id=1 cycle=2 pc=0 insn=2023 store=1 addr=100",
                 "MEM_REQUEST id=1 cycle=5 pc=0 write=1 addr=100 killed=0",
                 "MEM_RESPONSE id=1 cycle=9 pc=0 write=1 killed=0",
                 "DISPATCH id=2 cycle=10 pc=4 insn=2023", "ISSUE id=2 cycle=11 pc=4 insn=2023",
                 "MEM_REQUEST id=2 cycle=12 pc=4 write=1 addr=80000000 killed=0",
                 "COMMIT id=2 cycle=12 pc=4 insn=2023 store=1 addr=80000000"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sim.log"
            path.write_text("".join("CPU_TRACE " + line + "\n" for line in lines)
                            + "PASS cycles=15 result=0 expected=0\n")
            report = analyze(path)
        self.assertEqual(report["store_request_to_response"]["mean"], 4)
        self.assertEqual(report["store_commit_to_request"]["sum"], 3)
        self.assertEqual(report["store_commit_to_rob_retire"]["mean"], 0)
        self.assertEqual(report["counts"]["stores_retired_before_request"], 1)
        self.assertEqual(report["store_request_to_rob_retire"]["count"], 0)

    def test_store_gap_bounds_exclude_unready_successor_from_lower_bound(self):
        lines = [
            "DISPATCH id=1 cycle=0 pc=0 insn=2023", "ISSUE id=1 cycle=1 pc=0 insn=2023",
            "DISPATCH id=2 cycle=0 pc=4 insn=13", "ISSUE id=2 cycle=2 pc=4 insn=13",
            "COMPLETE id=2 cycle=2 pc=4 insn=13", "COMMIT id=1 cycle=3 pc=0 insn=2023 store=1 addr=100",
            "MEM_RESPONSE id=1 cycle=8 pc=0 write=1 killed=0", "STORE_RETIRE id=1 cycle=9 pc=0",
            "COMMIT id=2 cycle=10 pc=4 insn=13 store=0",
            "DISPATCH id=3 cycle=11 pc=8 insn=2023", "ISSUE id=3 cycle=12 pc=8 insn=2023",
            "COMMIT id=3 cycle=13 pc=8 insn=2023 store=1 addr=104",
            "DISPATCH id=5 cycle=14 pc=10 insn=2023", "ISSUE id=5 cycle=15 pc=10 insn=2023",
            "DISPATCH id=4 cycle=14 pc=c insn=2083", "ISSUE id=4 cycle=20 pc=c insn=2083",
            "COMPLETE id=4 cycle=24 pc=c insn=2083", "COMMIT id=4 cycle=25 pc=c insn=2083 store=0",
            "COMMIT id=5 cycle=26 pc=10 insn=2023 store=1 addr=80000000",
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sim.log"
            path.write_text("".join("CPU_TRACE " + line + "\n" for line in lines)
                            + "PASS cycles=30 result=0 expected=0\n")
            report = analyze(path)
        self.assertEqual(report["commit_gaps"]["post_store_ready_successor_idle_lower_bound"], 6)
        self.assertEqual(report["commit_gaps"]["post_store_idle_cycles_upper_bound"], 17)
        self.assertEqual(report["commit_gaps"]["all_commit_idle_cycles"], 19)
        self.assertEqual(report["load_issue_to_complete"]["mean"], 4)
        self.assertEqual(report["counts"]["stores_with_ready_successor"], 1)
        self.assertEqual(report["store_request_to_response"]["sum"], 5)
        self.assertEqual(report["store_request_to_rob_retire"]["sum"], 6)
        self.assertEqual(report["stores_without_retire_event"], 2)
        self.assertEqual(report["exit_request_to_sim_end"], 3)


if __name__ == "__main__":
    unittest.main()
