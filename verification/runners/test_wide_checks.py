"""Negative controls for the multi-lane evidence checker."""
import unittest
from wide_checks import check_wide


def events():
    # addi x5,x1,1 followed by addi x5,x5,2: same-pair RAW and WAW.
    a = {"id": 1, "cycle": 1, "pc": 0, "insn": 0x00108293, "rd": 5, "pdst": 32}
    b = {"id": 2, "cycle": 1, "pc": 4, "insn": 0x00228293, "rd": 5, "pdst": 33}
    # The dependent integer executes one cycle later, beside an independent LW.
    c = {"id": 3, "cycle": 2, "pc": 8, "insn": 0x00012303, "rd": 6, "pdst": 34}
    return [("DISPATCH", a), ("DISPATCH", b),
            ("DISPATCH", c), ("ISSUE", {**a, "cycle": 3}),
            ("ISSUE", {**b, "cycle": 4}), ("ISSUE", {**c, "cycle": 4}),
            ("COMMIT", {**a, "cycle": 5}), ("COMMIT", {**b, "cycle": 5}),
            ("COMMIT", {**c, "cycle": 6})]


class WideChecks(unittest.TestCase):
    def test_positive(self):
        self.assertIsNone(check_wide({"rename_pairs": 1, "issue_pairs": 1, "commit_pairs": 1, "raw_waw": True}, events())[0])

    def test_dispatch_alone_is_not_retired_width(self):
        self.assertIsNotNone(check_wide({"commit_pairs": 1}, [e for e in events() if e[0] != "COMMIT"])[0])

    def test_wrong_path_issue_does_not_count(self):
        self.assertIsNotNone(check_wide({"issue_pairs": 1}, [e for e in events() if not (e[0] == "COMMIT" and e[1]["id"] == 2)])[0])

    def test_different_cycles_are_not_a_pair(self):
        rows = [(k, {**f, "cycle": f["cycle"] + f["id"]}) for k, f in events()]
        self.assertIsNotNone(check_wide({"rename_pairs": 1}, rows)[0])

    def test_independent_waw_is_not_raw(self):
        rows = [(k, {**f, "insn": 0x00208293} if f["id"] == 2 else f) for k, f in events()]
        self.assertIsNotNone(check_wide({"raw_waw": True}, rows)[0])

    def test_checkpoint_kills_its_partner(self):
        a = {"id": 1, "cycle": 1, "pc": 0, "insn": 0x00c002ef, "rd": 5, "pdst": 32}
        b = {"id": 2, "cycle": 1, "pc": 4, "insn": 0x00228293, "rd": 5, "pdst": 33}
        rows = [("DISPATCH", a), ("DISPATCH", b), ("FLUSH", {"id": 1, "cycle": 4, "selective": 1})]
        self.assertIsNone(check_wide({"control_pair_killed": True}, rows)[0])
        self.assertIsNotNone(check_wide({"control_pair_killed": True}, rows + [("COMMIT", {**b, "cycle": 5})])[0])


if __name__ == "__main__":
    unittest.main()
