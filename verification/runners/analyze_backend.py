#!/usr/bin/env python3
"""Observed backend occupancy and MDU retirement waits, not additive CPI causes."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path

from analyze_trace import distribution
from run_cpu import parse_trace, PASS


def analyze(path):
    states = defaultdict(dict)
    commits, events = [], defaultdict(list)
    cycles = None
    for line in path.open():
        passed = PASS.match(line.strip())
        if passed:
            cycles = int(passed[1])
        parsed = parse_trace(line)
        if not parsed:
            continue
        kind, f = parsed
        events[kind].append(f)
        if kind in ("DISPATCH", "ISSUE", "COMPLETE", "COMMIT", "MEM_REQUEST", "MEM_RESPONSE"):
            states[f["id"]][kind] = f
        if kind == "COMMIT":
            commits.append(f)
    if cycles is None:
        raise ValueError(f"No PASS: {path}")
    committed_ids = {f["id"] for f in commits}
    counts, services, head_wait = Counter(), defaultdict(list), Counter()
    mdu_examples = []
    previous_cycle = 0
    for commit in commits:
        insn, identity = commit["insn"], commit["id"]
        state = states[identity]
        if insn & 127 == 0x33 and insn >> 25 == 1:
            op = ("mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu")[(insn >> 12) & 7]
            counts[op] += 1
            issue, complete = state["ISSUE"]["cycle"], state["COMPLETE"]["cycle"]
            services[op].append(complete - issue)
            # The next retirement really is this MDU; these cycles cannot be
            # hidden behind older retirement on this observed execution.
            wait = max(0, min(commit["cycle"], complete) - max(previous_cycle + 1, issue))
            head_wait[op] += wait
            if wait and len(mdu_examples) < 5:
                mdu_examples.append({"id": identity, "pc": commit["pc"], "op": op,
                                     "issue": issue, "complete": complete,
                                     "previous_commit_cycle": previous_cycle, "head_wait": wait})
        previous_cycle = commit["cycle"]
    useful_issues = Counter(f["cycle"] for f in events["ISSUE"] if f["id"] in committed_ids)
    useful_completions = Counter(f["cycle"] for f in events["COMPLETE"] if f["id"] in committed_ids)
    retired_cycles = {f["cycle"] for f in commits}
    return {"source": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "cycles": cycles, "commits": len(commits), "ipc": len(commits) / cycles,
            "cycles_without_commit": cycles - len(retired_cycles),
            "cycles_without_useful_issue": cycles - len(useful_issues),
            "useful_completions_per_cycle": dict(Counter(useful_completions.values())),
            "event_counts": {kind: {"all": len(items),
                                     "committed": sum(f.get("id") in committed_ids for f in items)}
                             for kind, items in events.items() if kind != "CONFIG"},
            "mdu_retired_op_counts": dict(counts),
            "mdu_issue_to_complete": {op: distribution(values) for op, values in services.items()},
            "mdu_at_retirement_head_wait_cycles": dict(head_wait),
            "mdu_head_wait_examples": mdu_examples,
            "interpretation": "MDU head waits are observed next-retirement wait intervals, not a forecast of removable cycles. "
                              "Unit service, WB holds, issue bubbles and retirement bubbles overlap; do not add them."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    reports = {p.parent.name: analyze(p) for p in sorted(args.runs.glob("*/sim.log"))}
    if not reports:
        parser.error("no sim.log found")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(reports, indent=2) + "\n")
    for name, report in reports.items():
        print(name, "MDU", report["mdu_retired_op_counts"], "head waits", report["mdu_at_retirement_head_wait_cycles"])


if __name__ == "__main__":
    main()
