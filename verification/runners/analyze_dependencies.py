#!/usr/bin/env python3
"""Measure dependency timing and control-flow recovery from committed identities.

Gap partitions describe the next architectural instruction's observed state;
they do not assign causal stalls to individual RTL blocks. Ideal predictor
replay uses committed conditional-branch outcomes and immediate training, so it
is a direction-prediction experiment rather than a cycle-accurate CPU estimate.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path

from analyze_trace import distribution
from run_cpu import PASS, parse_trace


def source_registers(insn: int) -> tuple[int, ...]:
    opcode = insn & 127
    rs1, rs2 = (insn >> 15) & 31, (insn >> 20) & 31
    if opcode in (0x63, 0x23, 0x33):
        return rs1, rs2
    if opcode in (0x67, 0x03, 0x13):
        return (rs1,)
    return ()


def producer_kind(insn: int) -> str:
    if insn & 127 == 3:
        return "load"
    if insn & 127 == 0x33 and insn >> 25 == 1:
        return "mdu"
    if insn & 127 in (0x6F, 0x67):
        return "link"
    return "alu"


def signed(value: int) -> int:
    return value - (1 << 32) if value & (1 << 31) else value


def analyze(path: Path) -> dict:
    lifetimes = {}
    commits = []
    flushes = {}
    cycles = None
    for line in path.open():
        passed = PASS.match(line.strip())
        if passed:
            cycles = int(passed[1])
        event = parse_trace(line)
        if event is None:
            continue
        kind, fields = event
        identity = fields["id"]
        if kind in ("DISPATCH", "ISSUE", "COMPLETE"):
            lifetimes.setdefault(identity, {})[kind] = fields["cycle"]
        elif kind == "COMMIT":
            commits.append(fields)
            lifetimes[identity]["insn"] = fields["insn"]
        elif kind == "FLUSH":
            flushes[identity] = fields
    if cycles is None:
        raise ValueError(f"{path}: missing PASS")
    last_writer = [None] * 32
    values = [0] * 32
    dependency_gap = defaultdict(list)
    dependency_pairs = defaultdict(list)
    branches = defaultdict(lambda: {"count": 0, "taken": 0, "flushes": 0})
    direction_errors = Counter()
    per_pc_counter, global_counter, local_counter, local_histories = {}, {}, {}, {}
    global_history = 0
    branch_issue_to_flush = []
    branch_complete_to_commit = []
    gap_partition = Counter()
    previous = None
    for commit in commits:
        identity, insn = commit["id"], commit["insn"]
        state = lifetimes[identity]
        dispatch, issue = state["DISPATCH"], state["ISSUE"]
        complete = state.get("COMPLETE", issue)  # Stores finish AGU work at ISSUE.
        sources = [last_writer[register] for register in source_registers(insn)
                   if register and last_writer[register] is not None]
        if sources:
            latest = max(sources, key=lambda source: lifetimes[source]["COMPLETE"])
            ready = lifetimes[latest]["COMPLETE"]
            if dispatch <= ready:
                label = producer_kind(lifetimes[latest]["insn"])
                dependency_gap[label].append(issue - ready)
                if len(dependency_pairs[label]) < 5:
                    dependency_pairs[label].append({"producer_id": latest, "consumer_id": identity,
                                                    "ready": ready, "dispatch": dispatch, "issue": issue})
        if previous is not None:
            start, end = previous["cycle"] + 1, commit["cycle"]
            gap_partition["not_dispatched"] += max(0, min(end, dispatch) - start)
            gap_partition["dispatched_waiting_issue"] += max(0, min(end, issue) - max(start, dispatch))
            gap_partition["issued_waiting_complete"] += max(0, min(end, complete) - max(start, issue))
            gap_partition["complete_waiting_commit"] += max(0, end - max(start, complete))
        opcode = insn & 127
        if opcode in (0x63, 0x67, 0x6F):
            branch_complete_to_commit.append(commit["cycle"] - complete)
            if identity in flushes:
                branch_issue_to_flush.append(flushes[identity]["cycle"] - issue)
        if opcode == 0x63:
            pc = commit["pc"]
            a, b = (values[register] for register in source_registers(insn))
            taken = {0: a == b, 1: a != b, 4: signed(a) < signed(b),
                     5: signed(a) >= signed(b), 6: a < b, 7: a >= b}[(insn >> 12) & 7]
            branch = branches[f"{pc:08x}"]
            branch["count"] += 1
            branch["taken"] += taken
            branch["flushes"] += identity in flushes
            # Three intentionally simple direction-only design experiments.
            gi = ((pc >> 2) ^ global_history) & 1023
            lh = local_histories.get(pc, 0)
            li = (pc, lh)
            for name, table, key in (("unaliased_bimodal", per_pc_counter, pc),
                                     ("gshare_10", global_counter, gi),
                                     ("local_history_4", local_counter, li)):
                counter = table.get(key, 1)
                direction_errors[name] += (counter >= 2) != taken
                table[key] = min(3, counter + 1) if taken else max(0, counter - 1)
            global_history = ((global_history << 1) | taken) & 1023
            local_histories[pc] = ((lh << 1) | taken) & 15
        if commit["rd"]:
            last_writer[commit["rd"]] = identity
            values[commit["rd"]] = commit["value"]
        previous = commit
    return {"cycles": cycles, "commits": len(commits),
            "ready_to_issue_when_already_dispatched": {key: distribution(value) for key, value in dependency_gap.items()},
            "dependency_examples": dict(dependency_pairs),
            "mispredict_issue_to_flush": distribution(branch_issue_to_flush),
            "control_complete_to_commit": distribution(branch_complete_to_commit),
            "commit_gap_next_instruction_state": dict(gap_partition),
            "conditional_branch_counts": sum(item["count"] for item in branches.values()),
            "ideal_committed_direction_errors": dict(direction_errors),
            "conditional_branches_by_pc": dict(sorted(branches.items(), key=lambda item: -item[1]["flushes"]))}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    results = {path.parent.name: analyze(path) for path in sorted(args.runs.glob("*/sim.log"))}
    if not results:
        parser.error("no sim.log files found")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({"interpretation": __doc__, "results": results}, indent=2) + "\n")
    for name, result in results.items():
        print(name, "RAW", {key: (value["count"], value["median"], value["mean"])
                             for key, value in result["ready_to_issue_when_already_dispatched"].items()},
              "resolution-to-flush", result["mispredict_issue_to_flush"].get("mean"),
              "ideal-direction-errors", result["ideal_committed_direction_errors"])


if __name__ == "__main__":
    main()
