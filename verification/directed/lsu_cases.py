"""Programs for ordered LSU contexts and byte-wise older-Store forwarding.

All values are checked by the architectural model. Additional metadata asks the
TRACE runner to prove that the intended concurrent execution actually occurred.
"""
from __future__ import annotations


def build_lsu_programs(Program, legacy=False):
    def hit_window(p, kill):
        """A Store-to-Load port bubble queues hits across a real recovery.

        With one-cycle hits and direct requests, straight-line single issue
        has only one accepted hit outstanding. A queued Store burst plus the
        recovery response hold exercises two accepted contexts without slowing
        or backpressuring the simulator artificially.
        """
        p.li(1, 0x12345678)
        p.li(20, 0x18000)
        p.li(18, 1)
        p.data.setdefault(0x10000, 1)
        for offset in range(16):
            p.data[0x18000 + offset] = (offset * 17 + 1) & 255
        p.load("lw", 12, 20)
        p.load("lw", 13, 31)
        p.branch("bne", 13, 0, "window_ready")
        p.label("window_wait")
        p.jal(0, "window_wait")
        p.label("window_ready")
        p.jal(0, "window_warm")
        while p.pc % 128:
            p.i("addi", 0, 0, 0)
        p.label("window_critical")
        for offset in (0, 4, 8):
            p.store("sw", 1, 31, offset)
        if kill:
            p.load("lw", 3, 20)
            p.label("window_branch")
            p.branch("bne", 3, 0, "window_safe")
        loads = []
        for index in range(3):
            label = f"window_load_{index}"
            loads.append(label)
            p.label(label)
            p.load("lw", 7 + index, 20, 4 * (index + 1))
        if not kill:
            p.label("window_branch")
            p.branch("beq", 0, 0, "window_safe")
        p.label("window_warm")
        p.branch("bne", 18, 0, "window_back")
        p.label("window_safe")
        p.checksum(1)
        p.jal(0, "window_done")
        p.label("window_back")
        p.i("addi", 18, 0, 0)
        p.jal(0, "window_critical")
        p.label("window_done")
        p.lsu.append({"kind": "kill_multiple" if kill else "concurrent",
                      "branch_label": "window_branch", "load_labels": loads,
                      "replacement_labels": [], "minimum": 2,
                      "minimum_accepted_at_flush": 2, "require_reuse": False})

    def forwarding(partial):
        p = Program("lsu_forward_partial" if partial else "lsu_forward_youngest",
                    "Warm repeated pending Stores forward youngest matching bytes to a younger Load")
        p.li(1, 0xA1B2C3D4)
        p.li(2, 0x80)
        p.li(3, 0xFEDC)
        p.li(20, 0x71234567)
        p.li(21, 3)
        p.li(22, 37)
        for offset, byte in enumerate((0x44, 0x33, 0x22, 0x11)):
            p.data[0x10000 + offset] = byte
        p.label("loop")
        p.r("divu", 23, 20, 21)  # Older head prevents Store authorization.
        stores = []
        if not partial:
            p.label("word_store")
            p.store("sw", 1, 31)
            stores.append("word_store")
        p.label("byte_store")
        p.store("sb", 2, 31, 1)
        p.label("half_store")
        p.store("sh", 3, 31, 2)
        stores += ["byte_store", "half_store"]
        p.label("merged_load")
        p.load("lw", 4, 31)
        p.load("lb", 5, 31, 1)
        p.load("lh", 6, 31, 2)
        for register in (4, 5, 6, 23):
            p.checksum(register)
        p.i("addi", 1, 1, 17)
        p.i("xori", 2, 2, 0x55)
        p.i("addi", 3, 3, 37)
        p.i("addi", 22, 22, -1)
        p.branch("bne", 22, 0, "loop")
        p.finish()
        p.lsu.append({"kind": "forward", "load_label": "merged_load", "store_labels": stores,
                      "mask": 14 if partial else 15})
        return p

    def bypass():
        p = Program("lsu_nonalias_bypass", "Known nonalias Store remains uncommitted while younger Load enters LSU")
        p.li(1, 0x87654321)
        p.li(20, 0x71234567)
        p.li(21, 3)
        p.li(22, 37)
        p.label("loop")
        p.r("divu", 23, 20, 21)
        p.label("store")
        p.store("sw", 1, 31, 0)
        p.label("load")
        p.load("lw", 4, 31, 4)
        p.checksum(4)
        p.checksum(23)
        p.i("addi", 1, 1, 37)
        p.i("addi", 22, 22, -1)
        p.branch("bne", 22, 0, "loop")
        p.finish()
        p.data.update({0x10004: 0x80, 0x10005: 0xFE, 0x10006: 0xDC, 0x10007: 0xBA})
        p.lsu.append({"kind": "forward", "load_label": "load", "store_labels": ["store"], "mask": 0})
        return p

    def unknown_store(address):
        p = Program("lsu_unknown_address" if address else "lsu_unknown_data",
                    "Already allocated Load waits for an older Store's unknown address/data, across ROB wraps")
        p.li(1, 0x30000 if address else 0x71234567)
        p.li(2, 3)
        p.li(4, 0x89ABCDEF)
        p.li(22, 41)
        p.label("loop")
        p.r("divu", 3, 1, 2)
        p.label("store")
        p.store("sw", 4 if address else 3, 3 if address else 31)
        p.label("load")
        p.load("lw", 5, 31)
        p.checksum(5)
        p.i("addi", 4, 4, 37)
        p.i("addi", 22, 22, -1)
        p.branch("bne", 22, 0, "loop")
        p.finish()
        p.lsu.append({"kind": "unknown_store", "load_label": "load", "store_label": "store"})
        return p

    def concurrent():
        p = Program("lsu_multiple_loads", "Consecutive hit Loads overlap, then miss and queue wrap preserve response identities")
        for offset in range(512):
            p.data[0x10000 + offset] = (offset * 23 + 0x80) & 255
        p.li(22, 41)
        p.label("loop")
        labels = []
        for index in range(4):
            label = f"load_{index}"
            labels.append(label)
            p.label(label)
            p.load("lw", 4 + index, 31, index * 4)
        for register in range(4, 8):
            p.checksum(register)
        p.i("addi", 22, 22, -1)
        p.branch("bne", 22, 0, "loop")
        # Cold lines force queued requests to wait behind a miss. Every result
        # has a distinct value, so swapping context/destination is observable.
        for index in range(8):
            p.load("lw", 4 + index, 31, 128 + index * 32)
        for register in range(4, 12):
            p.checksum(register)
        if legacy:
            p.lsu.append({"kind": "concurrent", "load_labels": labels, "minimum": 2})
        else:
            hit_window(p, False)
        p.finish()
        return p

    def younger_store():
        p = Program("lsu_younger_store_age", "Known younger Store cannot forward to or alter an older delayed Load")
        p.li(1, 0x89ABCDEF)
        p.li(2, 0x30000)
        p.li(3, 3)
        p.li(22, 37)
        for offset, byte in enumerate((0x44, 0x33, 0x22, 0x11)):
            p.data[0x10000 + offset] = byte
        p.label("loop")
        p.r("divu", 5, 2, 3)
        p.label("older_load")
        p.load("lw", 6, 5)
        p.label("younger_store")
        p.store("sw", 1, 31)
        p.checksum(6)
        p.load("lw", 7, 31)
        p.checksum(7)
        p.i("addi", 1, 1, 17)
        p.i("addi", 22, 22, -1)
        p.branch("bne", 22, 0, "loop")
        p.finish()
        p.lsu.append({"kind": "younger_store", "load_label": "older_load", "store_label": "younger_store"})
        return p

    def multiple_killed(cold):
        p = Program("lsu_killed_reuse" if cold else "lsu_killed_hits",
                    "Two younger Load contexts survive redirect only as canceled ordered responses")
        if not cold and not legacy:
            hit_window(p, True)
            p.finish()
            return p
        p.li(1, 0x18000)
        p.li(2, 1)
        p.li(6, 0)
        if not legacy:
            p.li(20, 0x1A000)
        if not cold and not legacy:
            p.load("lw", 3, 20)
        for base in (0x18000, 0x19000):
            for offset in range(16):
                p.data[base + offset] = (base // 256 + offset * 17 + 1) & 255
        # First visit warms recovery, then one complete pass warms all critical
        # instruction lines and the hit data. The second pass takes the branch.
        p.jal(0, "safe")
        while p.pc % 16:
            p.i("addi", 0, 0, 0)
        p.label("producer")
        if legacy:
            p.r("divu", 3, 1, 2)
        elif cold:
            p.r("divu", 3, 6, 2)
        else:
            p.load("lw", 3, 20)
        p.label("branch")
        p.branch("bne", 6 if legacy else 3, 0, "safe")
        labels = []
        for index in range(3):
            label = f"wrong_{index}"
            labels.append(label)
            p.label(label)
            p.load("lw", 7 + index, 3 if legacy else 1, index * 4)
        # Wait for every warm-up response before changing phase; a speculative
        # second iteration behind a cold first miss would alter the intended
        # branch/response timing and physical free-list state.
        if legacy:
            p.jal(0, "warm_back")
        else:
            p.branch("bne", 9, 0, "warm_back")
        while p.pc % 16:
            p.i("addi", 0, 0, 0)
        p.label("safe")
        p.r("divu", 14, 1, 2)
        replacement = []
        for index, register in enumerate((7, 8, 9) if legacy else (7, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19)):
            label = f"replacement_{index}"
            replacement.append(label)
            p.label(label)
            p.i("addi", register, 0, 0x123 + index)
        p.branch("beq", 6, 0, "producer")
        for register in (7, 8, 9, 14):
            p.checksum(register)
        p.finish()
        p.label("warm_back")
        p.li(6, 1)
        if not cold and not legacy:
            p.store("sw", 6, 20)
        p.li(1, 0x19000 if cold else 0x18000)
        p.jal(0, "producer")
        p.lsu.append({"kind": "kill_multiple", "branch_label": "branch", "load_labels": labels,
                      "replacement_labels": replacement, "minimum": 2,
                      "minimum_accepted_at_flush": 1 if cold else 2, "require_reuse": cold})
        return p

    def committed_store_flush():
        p = Program("lsu_committed_store_flush", "Redirect preserves retired buffered Stores and younger Loads observe every byte")
        p.li(1, 0x51234567)
        p.li(22, 41)
        p.label("loop")
        p.label("older_store")
        p.store("sw", 1, 31)
        p.label("branch")
        p.branch("beq", 0, 0, "safe")
        p.store("sw", 0, 31)  # Wrong-path overwrite must never enter memory.
        p.label("safe")
        p.load("lw", 4, 31)
        p.checksum(4)
        p.i("addi", 1, 1, 31)
        p.i("addi", 22, 22, -1)
        p.branch("bne", 22, 0, "loop")
        p.finish()
        p.lsu.append({"kind": "retired_store_flush", "store_label": "older_store", "branch_label": "branch"})
        return p

    return [forwarding(False), forwarding(True), bypass(), unknown_store(True), unknown_store(False),
            concurrent(), younger_store(), multiple_killed(False), multiple_killed(True), committed_store_flush()]
