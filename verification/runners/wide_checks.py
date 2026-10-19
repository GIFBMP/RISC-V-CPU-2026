"""Evidence for actual multi-lane use, in addition to architectural comparison."""
from collections import defaultdict


def check_wide(requirements, events):
    committed = {f["id"] for k, f in events if k == "COMMIT"}
    groups = {kind: defaultdict(list) for kind in ("DISPATCH", "ISSUE", "COMMIT")}
    flushes = {f["id"]: f for k, f in events if k == "FLUSH" and f.get("selective")}
    for kind, fields in events:
        if kind in groups:
            groups[kind][fields["cycle"]].append(fields)
    proof = {}
    for kind, key in (("DISPATCH", "rename_pairs"), ("ISSUE", "issue_pairs"), ("COMMIT", "commit_pairs")):
        pairs = [rows for rows in groups[kind].values()
                 if len([r for r in rows if r["id"] in committed]) >= 2]
        proof[key] = len(pairs)
        # Rename must also cover wrong-path groups for the checkpoint test.
        if key == "rename_pairs" and requirements.get("control_pair_killed"):
            proof[key] = sum(len(rows) >= 2 for rows in groups[kind].values())
        if proof[key] < requirements.get(key, 0):
            return f"insufficient genuine {key}: {proof[key]}", proof
    for rows in groups["DISPATCH"].values():
        rows = sorted(rows, key=lambda r: r["id"])
        for a, b in zip(rows, rows[1:]):
            rd, insn = a.get("rd", 0), b["insn"]
            opcode, rs1, rs2 = insn & 0x7f, (insn >> 15) & 31, (insn >> 20) & 31
            raw = (opcode in (0x13, 0x33) and rs1 == rd) or (opcode == 0x33 and rs2 == rd)
            if rd and raw and b.get("rd") == rd and a["id"] in committed and b["id"] in committed:
                proof["raw_waw"] = {"first": a, "second": b}
            if (a["insn"] & 0x7f in (0x63, 0x67, 0x6f) and a["id"] in flushes
                    and b["id"] not in committed and b.get("rd", 0)):
                proof["control_pair_killed"] = {"first": a, "second": b, "flush": flushes[a["id"]]}
    for key in ("raw_waw", "control_pair_killed"):
        if requirements.get(key) and key not in proof:
            return f"no genuine {key} pair observed", proof
    return None, proof
