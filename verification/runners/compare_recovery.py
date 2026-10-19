#!/usr/bin/env python3
"""Compare the same EX-resolution to next architectural rename interval.

A control must eventually commit and have both EARLY_FETCH and FLUSH events.
Its next architectural instruction must be dispatched at the resolved target.
This excludes killed controls and unrelated old retirement during recovery.
"""
import argparse
import hashlib
import json
from pathlib import Path

from analyze_trace import distribution
from run_cpu import parse_trace


def analyze(path):
    early, dispatch, flush, commits = {}, {}, {}, []
    for line in path.open():
        parsed = parse_trace(line)
        if not parsed:
            continue
        kind, fields = parsed
        identity = fields["id"]
        if kind == "EARLY_FETCH":
            early.setdefault(identity, fields)
        elif kind == "DISPATCH":
            dispatch[identity] = fields
        elif kind == "FLUSH":
            flush[identity] = fields
        elif kind == "COMMIT":
            commits.append(fields)
    delays, examples = [], []
    for control, successor in zip(commits, commits[1:]):
        identity = control["id"]
        if identity not in early or identity not in flush:
            continue
        resolution = early[identity]
        allocation = dispatch[successor["id"]]
        delay = allocation["cycle"] - resolution["cycle"]
        if successor["pc"] != resolution["target"] or delay < 0:
            raise ValueError(f"invalid resolved successor for control id={identity}: {path}")
        delays.append(delay)
        if len(examples) < 3:
            examples.append({"control_id": identity, "control_pc": control["pc"],
                             "resolve_cycle": resolution["cycle"], "flush_cycle": flush[identity]["cycle"],
                             "next_committed_id": successor["id"], "next_pc": successor["pc"],
                             "next_dispatch_cycle": allocation["cycle"], "delay": delay})
    return {"source": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "resolution_to_next_architectural_dispatch": distribution(delays), "examples": examples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--baseline-name", default="baseline")
    parser.add_argument("--candidate-name", default="candidate")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.baseline_name == args.candidate_name:
        parser.error("version names must differ")
    report = {"definition": "For every eventually committed control with EARLY_FETCH and FLUSH, measure "
              "DISPATCH of its next architecturally committed instruction minus that control EARLY_FETCH cycle. "
              "Same EX-resolution and rename-allocation stages in both versions. Killed controls and unrelated "
              "next commits are excluded. Sum is an exposure metric, not additive causal CPI or removable-cycle estimate.",
              "versions": {}}
    for name, folder in ((args.baseline_name, args.baseline), (args.candidate_name, args.candidate)):
        programs = {p.parent.name: analyze(p) for p in sorted(folder.glob("*/sim.log"))}
        count = sum(r["resolution_to_next_architectural_dispatch"]["count"] for r in programs.values())
        total = sum(r["resolution_to_next_architectural_dispatch"].get("sum", 0) for r in programs.values())
        if not count:
            parser.error(f"no committed recovery events found: {folder}")
        report["versions"][name] = {"programs": programs, "all_six_event_weighted_mean": total / count,
                                    "count": count, "sum": total}
        print(f"{name}: events={count} mean={total / count:.9f}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
