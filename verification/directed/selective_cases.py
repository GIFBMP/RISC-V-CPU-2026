"""Selective recovery retains old execution and restores branch-time mappings."""


def build_selective_programs(Program, wide=False):
    programs = []
    for operation, padding in (("mdu", 0), ("load", 0), ("store", 0), ("jalr", 0), ("mdu", 13)):
        p = Program("selective_wrap_mdu" if padding else "selective_keep_" + operation,
                    "Recover younger control flow while older work remains live and finishes exactly once")
        p.li(1, 0x71234567)
        p.li(2, 3)
        p.li(6, 0x18000)
        p.li(8, 1)
        p.address(10, "safe")
        for i, byte in enumerate((0xAB, 0xCD, 0xEF, 0x89)):
            p.data[0x18000 + i] = byte
        for _ in range(padding):
            p.i("addi", 0, 0, 0)
        p.jal(0, "warm_tail")
        while p.pc % 128:
            p.i("addi", 0, 0, 0)
        p.label("critical")
        p.label("older")
        if operation == "load":
            p.load("lw", 3, 6)
        else:
            p.r("divu", 3, 1, 2)
        if operation == "store":
            p.label("older_store")
            p.store("sw", 3, 31)
        p.label("branch")
        if operation == "jalr":
            p.jalr(10, 10)  # Checkpoint must contain this instruction's link.
        else:
            p.branch("beq", 0, 0, "safe")
        p.i("addi", 3, 0, 17)  # Younger WAW must not hide the saved older mapping.
        p.store("sw", 0, 31)
        p.emit(0xFFFFFFFF, ".word 0xffffffff")
        p.label("safe")
        p.i("addi", 7, 0, 0x123)  # Independent target executes before old result.
        p.i("addi", 4, 3, 37)
        if operation == "store":
            p.load("lw", 5, 31)
            p.checksum(5)
        p.checksum(4)
        p.checksum(10)
        p.label("warm_tail")
        p.branch("bne", 8, 0, "warm_back")
        p.finish()
        p.label("warm_back")
        p.i("addi", 8, 0, 0)
        p.jal(0, "critical")
        p.recovery.append({"kind": "selective_keep", "operation": operation,
                           "older_label": "older_store" if operation == "store" else "older",
                           "branch_label": "branch", "target_label": "safe",
                           "early_resume": operation != "store", "wrap": bool(padding)})
        programs.append(p)
    p = Program("selective_response_collision", "Ready older Load and MDU results are held on recovery and later complete exactly once")
    p.li(1, 0x71234567)
    p.li(2, 3)
    p.li(6, 0x18000)
    for i, byte in enumerate((0x00, 0x80, 0x01, 0x00)):
        p.data[0x18000 + i] = byte  # Pointer chain repeatedly hits the same line.
    p.load("lw", 4, 6)
    p.branch("bne", 4, 0, "start")
    p.label("start")
    old_sites = {1: [], 2: []}
    for source, delays in ((1, [(d, 0) for d in range(6)]),
                           (2, [(d, f) for d in range(4, 15) for f in range(4)] if wide
                            else [(5, 0), (5, 1), (5, 2), (8, 0), (8, 1)])):
        for delay, fine in delays:
            prefix = f"source{source}_delay{delay}_fine{fine}"
            p.i("addi", 8, 0, 1)
            p.r("add", 4, 6, 0)
            p.i("addi", 0, 0, 0)
            p.jal(0, prefix + "_warm")
            while p.pc % 128:
                p.i("addi", 0, 0, 0)
            p.label(prefix + "_entry")
            if source in (1, 2):
                # A hit Store occupies the single data port and forces this
                # older Load through the ordered queue even with direct Load
                # request bypass, creating a real response/recovery collision.
                for _ in range(3):
                    p.store("sw", 6, 6)
            p.label(prefix + "_old")
            old_sites[source].append(prefix + "_old")
            if source == 1:
                p.load("lw", 3, 6)
            else:
                p.r("divu", 3, 1, 2)
            for _ in range(delay):
                if source == 1:
                    p.i("addi", 4, 4, 1)
                else:
                    p.load("lw", 4, 4)
            for _ in range(fine):
                p.i("addi", 4, 4, 0)
            p.branch("bne", 4, 0, prefix + "_safe")
            p.i("addi", 3, 0, 17)
            p.label(prefix + "_safe")
            p.r("xor", 28, 28, 3)
            p.label(prefix + "_warm")
            p.branch("bne", 8, 0, prefix + "_back")
            p.jal(0, prefix + "_next")
            p.label(prefix + "_back")
            p.i("addi", 8, 0, 0)
            p.jal(0, prefix + "_entry")
            p.label(prefix + "_next")
    p.finish()
    for source in (1, 2):
        p.recovery.append({"kind": "selective_hold", "source": source, "older_labels": old_sites[source]})
    programs.append(p)
    p = Program("selective_checkpoint_full", "Four branch checkpoints fill behind an old DIV and the fifth resumes after retirement releases one")
    p.li(1, 0x71234567)
    p.li(2, 3)
    p.jal(0, "critical")
    while p.pc % 128:
        p.i("addi", 0, 0, 0)
    p.label("critical")
    p.r("divu", 3, 1, 2)
    branches = []
    for i in range(5):
        label = f"branch_{i}"
        p.label(label)
        branches.append(label)
        p.branch("beq", 0, 1, "end")
    p.label("end")
    p.checksum(3)
    p.finish()
    p.recovery.append({"kind": "selective_checkpoint_full", "older_label": "critical",
                       "branch_labels": branches, "capacity": 4})
    programs.append(p)
    return programs
