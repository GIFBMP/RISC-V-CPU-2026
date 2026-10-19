#!/usr/bin/env python3
"""Retired-order predictor design screen; excludes speculative timing/history.

BTB remains 64 entries with full-PC tags and index (PC>>2 XOR PC>>8)&63.
The baseline matches the current bimodal/local1 two-bit tournament. Gshare
PHTs have 64..1024 two-bit counters; only architectural conditional branches
advance the GHR. Both truncation and XOR-folding are reported when history is
wider than the PHT index. A per-BTB-row chooser resets on a tag replacement.
"""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from run_cpu import parse_trace


def load_records(path):
    commits = []
    with path.open() as stream:
        for line in stream:
            if "CPU_TRACE COMMIT " in line:
                commits.append(parse_trace(line)[1])
    records = []
    for event, following in zip(commits, commits[1:]):
        insn, pc = event["insn"], event["pc"]
        opcode = insn & 127
        if opcode not in (0x63, 0x67, 0x6F):
            continue
        conditional = opcode == 0x63
        if conditional:
            imm = ((insn >> 31) << 12 | ((insn >> 7) & 1) << 11
                   | ((insn >> 25) & 63) << 5 | ((insn >> 8) & 15) << 1)
            if imm & 4096:
                imm -= 8192
            if imm == 4:
                raise ValueError("PC+4 branch requires register-value outcome reconstruction")
            target = (pc + imm) & 0xFFFFFFFF
            taken = following["pc"] != (pc + 4) & 0xFFFFFFFF
        else:
            target, taken = following["pc"], True
        records.append((pc, conditional, taken, target, following["pc"]))
    return records


def counter_update(counter, taken):
    return min(3, counter + 1) if taken else max(0, counter - 1)


def simulate(records, size=64, history_bits=6, mode="baseline", folding="truncate"):
    btb = [None] * 64
    counters = [1] * size
    history = 0
    counts, pcs = Counter(), Counter()
    index_bits, mask = size.bit_length() - 1, size - 1
    for pc, conditional, taken, target, actual_next in records:
        bidx = ((pc >> 2) ^ (pc >> 8)) & 63
        entry = btb[bidx]
        hit = entry is not None and entry["pc"] == pc
        hindex = history
        if folding == "fold":
            hindex = 0
            for shift in range(0, history_bits, index_bits):
                hindex ^= history >> shift
        gidx = ((pc >> 2) ^ hindex) & mask
        global_taken = counters[gidx] >= 2
        bimodal = hit and entry["bimodal"] >= 2
        local = hit and entry["local"][entry["history"]] >= 2
        baseline = local if hit and entry["chooser"] >= 2 else bimodal
        primary = local if mode == "local_global" else baseline
        if mode == "global":
            direction = global_taken
        elif mode in ("local_global", "baseline_global"):
            direction = global_taken if hit and entry["global_chooser"] >= 2 else primary
        else:
            direction = baseline
        predicted = entry["target"] if hit and (not conditional or direction) else (pc + 4) & 0xFFFFFFFF
        if predicted != actual_next:
            counts["total"] += 1
            counts["conditional" if conditional else "jump"] += 1
            counts["direction_or_target" if hit else "collision" if entry is not None else "cold"] += 1
            pcs[pc] += 1
        if conditional:
            # Oracle measures the best per-occurrence choice between these
            # two component predictions; it is explicitly not implementable.
            if (not hit and taken) or (hit and primary != taken and global_taken != taken):
                counts["conditional_oracle_two_components"] += 1
            if hit and primary != global_taken:
                entry["global_chooser"] = counter_update(entry["global_chooser"], global_taken == taken)
            counters[gidx] = counter_update(counters[gidx], taken)
            history = ((history << 1) | int(taken)) & ((1 << history_bits) - 1)
        if not hit:
            btb[bidx] = {"pc": pc, "target": target, "bimodal": 2 if taken else 1,
                         "history": int(taken), "local": [2 if taken else 0, 1],
                         "chooser": 1, "global_chooser": 1}
        else:
            if conditional:
                if local != bimodal:
                    entry["chooser"] = counter_update(entry["chooser"], local == taken)
                lh = entry["history"]
                entry["local"][lh] = counter_update(entry["local"][lh], taken)
                entry["history"] = int(taken)
                entry["bimodal"] = counter_update(entry["bimodal"], taken)
            else:
                entry["bimodal"] = 3
            entry["target"] = target
    return {"counts": dict(counts), "by_pc": {f"{pc:08x}": n for pc, n in pcs.most_common()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    report = {"interpretation": __doc__, "cases": {}}
    for log in sorted(args.runs.glob("*/sim.log")):
        records = load_records(log)
        baseline = simulate(records)
        variants = {}
        for size in (64, 128, 256, 512, 1024):
            for history in (4, 6, 8, 10):
                for folding in ("truncate", "fold"):
                    for mode in ("global", "local_global", "baseline_global"):
                        name = f"{mode}_pht{size}_ghr{history}_{folding}"
                        variants[name] = simulate(records, size, history, mode, folding)
        report["cases"][log.parent.name] = {"source": str(log.resolve()),
                                             "source_sha256": hashlib.sha256(log.read_bytes()).hexdigest(),
                                             "controls": len(records), "baseline": baseline, "variants": variants}
        best = min(variants, key=lambda key: variants[key]["counts"].get("total", 0))
        print(log.parent.name, "baseline", baseline["counts"], "best", best, variants[best]["counts"], flush=True)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
