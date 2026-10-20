"""Strict stimuli for V7's variable-stage Loads and broadened dual lanes."""


def build_v7_programs(Program):
    from v7_design_probes import build
    programs = []
    for store, load, offset in (("sw", "lw", 0), ("sb", "lbu", 1), ("sh", "lhu", 2)):
        for alias in (True, False):
            p = build(alias, store, load, offset)
            p.v7.append({"kind": "late_store", "alias": alias, "store_label": "store",
                         "load_label": "load", "producer_label": "producer"})
            programs.append(p)

    p = Program("v7_lane_pairs", "Two memory renames, shared integer lanes and second-position noninteger retirement")
    p.li(1, 0xF1234567)
    p.li(2, 3)
    p.li(20, 17)
    p.label("loop")
    # A changing divisor avoids result reuse; the full-width multiplier below
    # avoids early termination. These delays exercise the original lane-pair
    # scheduling obligations independently of the MDU's arithmetic shortcuts.
    p.r("divu", 9, 1, 20)
    if p.pc % 8:
        p.i("addi", 0, 0, 0)
    p.store("sw", 1, 31)
    p.load("lw", 5, 31)  # Same-pair older-store mask and later forwarding.
    p.load("lw", 6, 31)
    p.load("lw", 7, 31)
    p.i("addi", 10, 1, 1)
    p.store("sb", 10, 31, 1)
    p.i("addi", 11, 1, 2)
    p.load("lbu", 12, 31, 1)
    p.i("addi", 13, 1, 3)
    p.r("mul", 14, 2, 1)
    for reg in range(15, 19):
        p.i("addi", reg, 1, reg)
    p.store("sw", 18, 31, 4)
    p.branch("beq", 1, 0, "end")
    for reg in (5, 6, 7, 9, 10, 11, 12, 13, 14, 18):
        p.checksum(reg)
    p.i("addi", 20, 20, -1)
    p.branch("bne", 20, 0, "loop")
    p.label("end")
    p.finish()
    p.v7.append({"kind": "pairs", "pairs": {
        "DISPATCH": ["store+load", "load+load", "integer+store", "integer+load", "integer+mdu"],
        "SELECT": ["integer+integer", "store+control"],
        "COMMIT": ["integer+store", "integer+load"]}})
    programs.append(p)

    p = Program("v7_mixed_retire", "Completed MDU and control flow retire in the second position behind an older delay")
    p.li(1, 0x71234567)
    p.li(2, 3)
    p.li(21, 0x18000)
    p.load("lw", 11, 21)
    p.i("addi", 13, 11, 3)
    p.r("mul", 14, 1, 2)
    p.r("divu", 9, 1, 2)
    for reg in (15, 16, 17):
        p.i("addi", reg, 1, reg)
    p.store("sw", 1, 31)
    p.branch("bne", 0, 0, "end")
    p.label("end")
    for reg in (9, 13, 14, 15, 16, 17):
        p.checksum(reg)
    p.finish()
    p.v7.append({"kind": "pairs", "pairs": {"COMMIT": ["integer+mdu", "store+control"]}})
    programs.append(p)

    p = Program("v7_second_checkpoint", "Second-position JALR keeps first mapping and its own link, including same-pair RAW/WAW")
    for i in range(8):
        target = f"target_{i}"
        p.address(6, target)
        if p.pc % 8:
            p.i("addi", 0, 0, 0)
        if i % 2:
            p.i("addi", 7, 0, 17 + i)
            p.jalr(5, 6)
        else:
            p.i("addi", 5, 6, 0)
            p.jalr(5, 5)
        p.i("addi", 5, 0, 99)
        p.i("addi", 7, 0, 99)
        p.store("sw", 0, 31)
        if p.pc % 8:
            p.i("addi", 0, 0, 0)
        p.label(target)
        p.checksum(5)
        p.checksum(7)
    p.finish()
    p.v7.append({"kind": "second_checkpoint"})
    programs.append(p)

    # Build a separate branch/retry case so the compact deadlock regressions
    # above retain their original machine images.
    p = Program("v7_retry_recovery", "An older aliasing Load retries across a younger branch recovery without losing its identity")
    p.li(1, 0x12345678)
    p.li(2, 19)
    p.r("div", 3, 1, 2)
    p.label("producer")
    p.r("div", 4, 1, 2)
    p.store("sw", 4, 31)
    p.label("load")
    p.load("lw", 5, 31)
    p.i("addi", 10, 0, 1)
    for _ in range(5):
        p.i("addi", 10, 10, 1)
    p.label("branch")
    p.branch("bne", 10, 0, "safe")
    p.store("sw", 0, 31)
    p.label("safe")
    p.i("addi", 11, 0, 17)
    for reg in (3, 4, 5, 11):
        p.checksum(reg)
    p.finish()
    p.v7.append({"kind": "retry_recovery", "load_label": "load", "branch_label": "branch"})
    programs.append(p)

    p = Program("v7_cancel_late_store", "A killed Store must never capture the delayed surviving producer's data")
    p.li(1, 0x12345678)
    p.li(2, 19)
    p.r("div", 3, 1, 2)
    p.label("producer")
    p.r("div", 4, 1, 2)
    p.i("addi", 10, 0, 1)
    for _ in range(6):
        p.i("addi", 10, 10, 1)
    p.label("branch")
    p.branch("bne", 10, 0, "safe")
    p.label("store")
    p.store("sb", 4, 31, 1)
    p.label("safe")
    for _ in range(40):
        p.i("addi", 7, 7, 1)
    p.load("lw", 5, 31)
    for reg in (3, 4, 5, 7):
        p.checksum(reg)
    p.finish()
    p.v7.append({"kind": "cancel_store_data", "store_label": "store", "branch_label": "branch",
                 "producer_label": "producer"})
    programs.append(p)
    return programs
