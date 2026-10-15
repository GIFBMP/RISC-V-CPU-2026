#!/usr/bin/env python3
"""Summarize committed CPU_TRACE instruction timing without modifying the DUT.

V1-V3 Store COMMIT is the irrevocable D-cache request handshake. V4 buffered
Store COMMIT is queue insertion/ROB retirement and may precede MEM_REQUEST.
Use explicit MEM_REQUEST when available, falling back to COMMIT only for older
traces. Post-Store gaps describe retirement intervals, not causal Store stalls.
Load lifetime and commit gaps overlap and must not be added as CPI components.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import statistics

from run_cpu import PASS, parse_trace


def distribution(values: list[int]) -> dict:
    if not values:
        return {"count": 0}
    ordered = sorted(values)
    return {"count": len(values), "sum": sum(values),
            "mean": round(statistics.mean(values), 3),
            "minimum": ordered[0], "median": statistics.median(ordered),
            "p90": ordered[(len(ordered) - 1) * 90 // 100],
            "p99": ordered[(len(ordered) - 1) * 99 // 100],
            "maximum": ordered[-1],
            "histogram": dict(sorted(Counter(values).items()))}


def analyze(path: Path) -> dict:
    lifecycle: dict[int, dict] = {}
    committed_controls: dict[int, int] = {}
    store_records: dict[int, dict] = {}
    counts: Counter = Counter()
    gaps: Counter = Counter()
    loads, load_queue, store_queue, branch_recovery = [], [], [], []
    store_response_latency, store_retire_latency = [], []
    load_accept_wait, load_response_latency, forwarding_masks = [], [], Counter()
    previous = None
    pending_flush = None
    cycles = None
    exit_request_cycle = None
    with path.open() as stream:
        for line in stream:
            passed = PASS.match(line.strip())
            if passed:
                cycles = int(passed[1])
            parsed = parse_trace(line)
            if parsed is None:
                continue
            kind, event = parsed
            identity = event["id"]
            state = lifecycle.setdefault(identity, {})
            if kind in ("DISPATCH", "ISSUE", "COMPLETE"):
                state[kind] = event["cycle"]
                state["insn"] = event["insn"]
                counts[kind.lower()] += 1
            elif kind == "DROP_LOAD":
                counts["dropped_loads"] += 1
            elif kind == "LOAD_QUEUE":
                state["LOAD_QUEUE"] = event["cycle"]
                state["mask"] = event["mask"]
            elif kind == "MEM_REQUEST":
                counts["explicit_memory_requests"] += 1
                state["MEM_REQUEST"] = event["cycle"]
                if event["write"]:
                    store_records.setdefault(identity, {})["request"] = event["cycle"]
            elif kind == "MEM_RESPONSE":
                counts["store_responses" if event["write"] else "load_responses"] += 1
                state["MEM_RESPONSE"] = event["cycle"]
                if event["write"]:
                    store_records.setdefault(identity, {})["response"] = event["cycle"]
            elif kind == "STORE_RETIRE":
                counts["store_retires"] += 1
                store_records.setdefault(identity, {})["retire"] = event["cycle"]
            elif kind == "FLUSH":
                counts["flushes"] += 1
                opcode = committed_controls.get(identity)
                counts["conditional_flushes" if opcode == 0x63 else "jump_flushes"] += 1
                pending_flush = event["cycle"]
            elif kind == "WB_STALL":
                counts[f"wb_stall_source_{event['source']}"] += 1
            elif kind == "COMMIT":
                opcode = event["insn"] & 0x7F
                counts["commits"] += 1
                if opcode in (0x63, 0x6F, 0x67):
                    committed_controls[identity] = opcode
                    counts["conditional_branches" if opcode == 0x63 else "jumps"] += 1
                if opcode == 0x03:
                    counts["loads"] += 1
                    loads.append(state["COMPLETE"] - state["ISSUE"])
                    load_queue.append(state["ISSUE"] - state["DISPATCH"])
                    if "MEM_REQUEST" in state and "MEM_RESPONSE" in state:
                        load_accept_wait.append(state["MEM_REQUEST"] - state.get("LOAD_QUEUE", state["ISSUE"]))
                        load_response_latency.append(state["MEM_RESPONSE"] - state["MEM_REQUEST"])
                    if "mask" in state:
                        forwarding_masks[state["mask"]] += 1
                if opcode == 0x23:
                    counts["stores"] += 1
                    store_records.setdefault(identity, {}).update({"commit": event["cycle"], "issue": state["ISSUE"],
                                                                   "address": event["addr"]})
                    if event["addr"] == 0x80000000:
                        counts["exit_stores"] += 1
                        exit_request_cycle = event["cycle"]
                if previous is not None:
                    idle = max(0, event["cycle"] - previous["cycle"] - 1)
                    gaps["all_commit_idle_cycles"] += idle
                    if previous["store"]:
                        counts["stores_with_successor"] += 1
                        gaps["post_store_idle_cycles_upper_bound"] += idle
                        ready_cycle = state.get("ISSUE") if opcode == 0x23 else state.get("COMPLETE")
                        if ready_cycle is not None and ready_cycle <= previous["cycle"]:
                            counts["stores_with_ready_successor"] += 1
                            gaps["post_store_ready_successor_idle_lower_bound"] += idle
                    if opcode == 0x03:
                        gaps["pre_load_commit_idle_cycles"] += idle
                if pending_flush is not None:
                    branch_recovery.append(event["cycle"] - pending_flush)
                    pending_flush = None
                previous = event
                lifecycle.pop(identity, None)
    if cycles is None:
        raise ValueError(f"{path}: simulator did not report PASS")
    store_commit_to_request, store_commit_to_retire, store_issue_to_commit = [], [], []
    for record in store_records.values():
        if "commit" not in record:
            continue
        request = record.get("request", record["commit"])
        store_queue.append(request - record["issue"])
        store_issue_to_commit.append(record["commit"] - record["issue"])
        store_commit_to_request.append(request - record["commit"])
        if "response" in record:
            store_response_latency.append(record["response"] - request)
        if "retire" in record:
            store_commit_to_retire.append(record["retire"] - record["commit"])
            if record["retire"] >= request:
                store_retire_latency.append(record["retire"] - request)
            else:
                counts["stores_retired_before_request"] += 1
        if record["address"] == 0x80000000:
            exit_request_cycle = request
    controls = counts["conditional_branches"] + counts["jumps"]
    return {"trace": str(path.resolve()), "cycles": cycles, "counts": dict(counts),
            "commit_gaps": dict(gaps),
            "post_store_ready_successor_fraction": round(gaps["post_store_ready_successor_idle_lower_bound"] / cycles, 6),
            "post_store_all_gap_fraction": round(gaps["post_store_idle_cycles_upper_bound"] / cycles, 6),
            "control_mispredict_fraction": round(counts["flushes"] / controls, 6) if controls else 0,
            "load_issue_to_complete": distribution(loads),
            "load_dispatch_to_issue": distribution(load_queue),
            "load_queue_to_request": distribution(load_accept_wait),
            "load_request_to_response": distribution(load_response_latency),
            "committed_load_forwarding_masks": dict(sorted(forwarding_masks.items())),
            "store_issue_to_request": distribution(store_queue),
            "store_issue_to_commit": distribution(store_issue_to_commit),
            "store_commit_to_request": distribution(store_commit_to_request),
            "store_commit_to_rob_retire": distribution(store_commit_to_retire),
            "store_request_to_response": distribution(store_response_latency),
            "store_request_to_rob_retire": distribution(store_retire_latency),
            "stores_without_retire_event": sum("retire" not in record for record in store_records.values()),
            # Official Memory.cycle starts at 1 where CPU_TRACE cycle starts at
            # 0. The simulator stops at exit B before the CPU response/retire.
            "exit_request_to_sim_end": None if exit_request_cycle is None else cycles - exit_request_cycle - 1,
            "flush_to_next_commit": distribution(branch_recovery)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=Path, required=True, help="one run_cpu timestamp directory")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--sim", type=Path, help="record exact simulator SHA-256")
    args = parser.parse_args()
    results = {path.parent.name: analyze(path) for path in sorted(args.runs.glob("*/sim.log"))}
    if not results:
        parser.error("no sim.log files found")
    report = {"interpretation": __doc__, "results": results}
    if args.sim:
        report["simulator"] = str(args.sim.resolve())
        report["simulator_sha256"] = hashlib.sha256(args.sim.read_bytes()).hexdigest()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    for name, result in results.items():
        counts, loads = result["counts"], result["load_issue_to_complete"]
        print(f"{name}: cycles={result['cycles']} loads={counts.get('loads', 0)} "
              f"stores={counts.get('stores', 0)} load_mean={loads.get('mean', 0)} "
              f"store_gap_bound={result['post_store_ready_successor_fraction']:.1%}..{result['post_store_all_gap_fraction']:.1%} "
              f"mispredict={result['control_mispredict_fraction']:.1%}")


if __name__ == "__main__":
    main()
