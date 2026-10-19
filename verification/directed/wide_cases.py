"""V6 timing stimuli and architectural hazards for asymmetric dual pipelines.

The scalar profiles remain unchanged. These programs keep the same LSU/recovery
obligations but expose overlap under paired fetch and a second integer pipe.
"""


def build_wide_programs(Program):
    programs = []
    for kill in (False, True):
        p = Program("lsu_killed_hits" if kill else "lsu_multiple_loads",
                    "Cold branch dependency overlaps four queued hot Loads across selective recovery")
        p.li(20, 0x18000)
        p.li(21, 0x1000)
        for i, byte in enumerate((0, 0x80, 1, 0)):
            p.data[0x18000 + i] = byte  # The warm word is its own address.
        for i, byte in enumerate((1, 0, 0, 0)):
            p.data[0x19000 + i] = byte
        for i in range(4, 20):
            p.data[0x18000 + i] = (17 * i + 1) & 255
        p.load("lw", 20, 20)
        p.r("add", 21, 20, 21)
        p.load("lw", 3, 21)
        if kill:
            p.label("branch")
            p.branch("bne", 3, 0, "safe")
        loads = []
        # One hot Load can issue ahead of the cold producer. The remaining
        # three queue behind it; two are still accepted at the recovery edge.
        for i in range(4):
            label = f"load_{i}"
            loads.append(label)
            p.label(label)
            p.load("lw", 7 + i, 20, (i + 1) * 4)
        if not kill:
            p.label("branch")
            p.branch("bne", 3, 0, "safe")
        p.store("sw", 0, 31)
        p.label("safe")
        p.checksum(3)
        if not kill:
            for i in range(4):
                p.checksum(7 + i)
        p.finish()
        p.lsu.append({"kind": "kill_multiple" if kill else "concurrent",
                      "branch_label": "branch", "load_labels": loads,
                      "replacement_labels": [], "minimum": 2,
                      "minimum_accepted_at_flush": 2, "require_reuse": False})
        programs.append(p)

    p = Program("lsu_committed_store_flush", "A data-dependent branch waits until a cold Store has retired into its persistent descriptor")
    p.li(1, 0x51234567)
    p.li(22, 41)
    p.label("loop")
    p.label("older_store")
    p.store("sw", 1, 31)
    p.i("addi", 5, 1, 0)
    for _ in range(7):
        p.i("addi", 5, 5, 1)
    p.label("branch")
    p.branch("bne", 5, 0, "safe")
    p.store("sw", 0, 31)
    p.label("safe")
    p.load("lw", 4, 31)
    p.checksum(4)
    p.i("addi", 1, 1, 31)
    p.i("addi", 22, 22, -1)
    p.branch("bne", 22, 0, "loop")
    p.finish()
    p.lsu.append({"kind": "retired_store_flush", "store_label": "older_store", "branch_label": "branch"})
    programs.append(p)

    p = Program("wide_rename_retire", "Paired RAW/WAW, x0, simultaneous execution and retirement while the ROB wraps")
    p.li(1, 0x71234567)
    p.li(2, 3)
    p.li(20, 17)
    p.label("loop")
    p.r("divu", 9, 1, 2)  # Completed younger integers collect behind this head.
    if p.pc % 8:
        p.i("addi", 0, 0, 0)
    p.i("addi", 5, 1, 1)
    p.i("addi", 5, 5, 2)  # Same-pair RAW and WAW, including old-pdst chaining.
    p.i("addi", 0, 5, 7)
    p.r("add", 6, 5, 5)
    p.store("sw", 6, 31)
    p.i("addi", 7, 6, 3)
    p.load("lw", 8, 31)
    p.r("xor", 10, 7, 6)
    for reg in (5, 6, 7, 8, 9, 10):
        p.checksum(reg)
    p.i("addi", 1, 1, 3)
    p.i("addi", 20, 20, -1)
    p.branch("bne", 20, 0, "loop")
    p.finish()
    p.wide = {"rename_pairs": 4, "issue_pairs": 4, "commit_pairs": 4, "raw_waw": True}
    programs.append(p)

    p = Program("wide_checkpoint_pair", "A JAL checkpoint retains its own link and excludes a same-pair younger WAW")
    for i in range(12):
        if p.pc % 8:
            p.i("addi", 0, 0, 0)
        p.jal(5, f"target_{i}")
        p.i("addi", 5, 5, 100)
        p.store("sw", 5, 31)
        p.label(f"target_{i}")
        p.checksum(5)
    p.finish()
    p.wide = {"rename_pairs": 4, "control_pair_killed": True}
    programs.append(p)
    return programs
