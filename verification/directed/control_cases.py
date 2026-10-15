"""Exercise early fetch redirection independently of architectural recovery."""


def build_control_programs(Program):
    programs = []
    for delayed in (False, True):
        p = Program("early_older_override" if delayed else "early_commit_collision",
                    "Older architectural recovery takes priority over a younger speculative fetch redirect")
        p.li(1, 0)
        p.li(2, 1)
        p.li(6, 0)
        p.jal(0, "critical")
        while p.pc % 128:
            p.i("addi", 0, 0, 0)
        p.label("critical")
        if delayed:
            p.r("divu", 3, 1, 2)
        p.label("older")
        p.branch("bne", 3 if delayed else 6, 0, "safe")
        p.label("younger")
        p.branch("bne", 6, 0, "wrong_target")
        p.jal(0, "warm_back")
        p.label("safe")
        p.i("addi", 7, 0, 0x123)
        p.checksum(7)
        p.checksum(6)
        p.finish()
        p.label("wrong_target")
        p.store("sw", 0, 31)
        p.emit(0xFFFFFFFF, ".word 0xffffffff")
        p.label("wrong_park")
        p.jal(0, "wrong_park")
        p.label("warm_back")
        p.li(1, 0x70000000)
        p.li(6, 1)
        p.jal(0, "critical")
        p.recovery.append({"kind": "older_override" if delayed else "commit_collision",
                           "older_label": "older", "younger_label": "younger", "target_label": "safe"})
        programs.append(p)
    return programs
