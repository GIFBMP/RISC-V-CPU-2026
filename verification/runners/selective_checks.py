"""Identity-based checks for recovery that preserves the branch and its elders.

The architectural comparator remains authoritative for values. These checks
prove timing and ownership: a canceled incarnation cannot return under a reused
ROB slot or physical destination, and older outstanding work is not restarted.
"""
from collections import defaultdict


def check_selective_invariants(events):
    cycles = defaultdict(list)
    for kind, fields in events:
        if "cycle" in fields:
            cycles[fields["cycle"]].append((kind, fields))
    live, canceled = {}, set()
    proof = {"selective_flushes": 0, "wrapped_preserved_windows": 0,
             "maximum_kept": 0, "maximum_killed": 0, "same_cycle_older_completion": 0,
             "same_cycle_older_retirement": 0}
    for cycle, group in sorted(cycles.items()):
        flushes = [f for kind, f in group if kind == "FLUSH"]
        for flush in flushes:
            if not flush.get("selective"):
                # Legacy V4 retires the branch first, then clears all younger
                # entries; preserve its original checker contract separately.
                canceled.update(live)
                live.clear()
                continue
            cut = flush["id"]
            if cut not in live:
                return f"selective cut id={cut} is not live at cycle {cycle}", proof
            keep = {i for i in live if i <= cut}
            kill = set(live) - keep
            if (flush.get("head_id") != min(live) or flush.get("kept") != len(keep)
                    or flush.get("killed") != len(kill)):
                return f"selective recovery ROB accounting differs at cycle {cycle}: live={sorted(live)} trace={flush}", proof
            proof["selective_flushes"] += 1
            proof["maximum_kept"] = max(proof["maximum_kept"], len(keep))
            proof["maximum_killed"] = max(proof["maximum_killed"], len(kill))
            if any(live[i].get("slot", 0) > live[cut].get("slot", 0) for i in keep):
                proof["wrapped_preserved_windows"] += 1
            for kind, fields in group:
                if fields.get("id", cut) < cut and fields.get("id") in keep:
                    proof["same_cycle_older_completion"] += kind == "COMPLETE"
                    proof["same_cycle_older_retirement"] += kind == "COMMIT"
            canceled.update(kill)
            for identity in kill:
                del live[identity]
        for kind, fields in group:
            identity = fields.get("id")
            if identity in canceled and kind in ("ISSUE", "COMPLETE", "COMMIT", "STORE_RETIRE"):
                return f"canceled id={identity} produced {kind} at cycle {cycle}", proof
            if kind == "DISPATCH":
                if identity in live or identity in canceled:
                    return f"allocation id={identity} was reused", proof
                live[identity] = fields
            elif kind == "STORE_RETIRE" or (kind == "COMMIT" and not fields.get("store")):
                if identity not in live:
                    return f"retiring id={identity} has no live ROB allocation", proof
                del live[identity]
    return None, proof


def check_selective_probe(probe, events):
    by_kind = defaultdict(dict)
    counts = defaultdict(int)
    for kind, fields in events:
        if "id" in fields:
            by_kind[kind][fields["id"]] = fields
            counts[kind, fields["id"]] += 1
    def matches(kind, pc):
        return [f for f in by_kind[kind].values() if f.get("pc") == pc]
    commits = by_kind["COMMIT"]
    if probe["kind"] == "selective_checkpoint_full":
        branches = []
        for pc in probe["branch_pcs"]:
            allocation = next((f for f in matches("DISPATCH", pc) if f["id"] in commits), None)
            if not allocation:
                return "checkpoint saturation branch did not retire", {}
            branches.append(allocation)
        old = next((f for f in matches("COMPLETE", probe["older_pc"]) if f["id"] in commits), None)
        n = probe["capacity"]
        if (not old or len(branches) != n + 1
                or any(a["cycle"] >= old["cycle"] for a in branches[:n])
                or any(by_kind["COMPLETE"].get(a["id"], {}).get("cycle", old["cycle"]) >= old["cycle"]
                       for a in branches[:n])
                or branches[n]["cycle"] <= commits[branches[0]["id"]]["cycle"]):
            return "four live completed controls and fifth rename resuming after checkpoint retirement were not observed", {}
        return None, {"older_completion": old, "full_allocations": branches[:n],
                      "first_checkpoint_retirement": commits[branches[0]["id"]], "resumed_fifth": branches[n]}
    if probe["kind"] == "selective_hold":
        for hold in by_kind["RECOVERY_HOLD"].values():
            identity = hold["id"]
            if hold.get("source") != probe["source"] or hold["pc"] not in probe["older_pcs"]:
                continue
            flush = next((f for f in by_kind["FLUSH"].values() if f.get("selective")
                          and f["cycle"] == hold["cycle"] and f["id"] > identity), None)
            complete = by_kind["COMPLETE"].get(identity)
            if not flush or not complete or identity not in commits or complete["cycle"] <= hold["cycle"]:
                continue
            if any(counts[kind, identity] != 1 for kind in ("ISSUE", "COMPLETE", "COMMIT")):
                return "held older result restarted or completed/retired more than once", {"hold": hold}
            if identity in by_kind["DROP_LOAD"] or identity in by_kind["DROP_MDU"]:
                return "held older result was canceled", {"hold": hold}
            return None, {"hold": hold, "flush": flush, "completion": complete, "commit": commits[identity]}
        return f"no older source {probe['source']} response held exactly on selective recovery", {}
    flushes = [f for f in matches("FLUSH", probe["branch_pc"]) if f.get("selective")]
    # New tests also run architecturally in EARLY_RECOVERY=0 builds, but their
    # strict timing requirement deliberately cannot pass without the mechanism.
    evidence = {"candidate_flushes": flushes}
    for flush in flushes:
        branch = commits.get(flush["id"])
        if not branch or branch["cycle"] <= flush["cycle"]:
            continue
        for allocation in matches("DISPATCH", probe["older_pc"]):
            identity = allocation["id"]
            commit = commits.get(identity)
            issue = by_kind["ISSUE"].get(identity)
            if (identity >= flush["id"] or not issue or not commit
                    or allocation["cycle"] >= flush["cycle"]
                    or commit["cycle"] <= flush["cycle"] or commit["seq"] >= branch["seq"]):
                continue
            if counts["ISSUE", identity] != 1 or counts["COMMIT", identity] != 1:
                return "preserved instruction was restarted or committed twice", evidence
            completion = by_kind["COMPLETE"].get(identity)
            if probe["operation"] in ("mdu", "load", "jalr"):
                if (not completion or not issue["cycle"] < flush["cycle"] < completion["cycle"]
                        or counts["COMPLETE", identity] != 1):
                    continue
            elif probe["operation"] == "store":
                if issue["cycle"] <= flush["cycle"]:
                    continue  # Must preserve an older not-yet-executed IQ entry.
            if probe["operation"] == "load":
                request, response = by_kind["MEM_REQUEST"].get(identity), by_kind["MEM_RESPONSE"].get(identity)
                if not request or not response or not request["cycle"] < flush["cycle"] < response["cycle"]:
                    continue
                if response.get("killed") or identity in by_kind["DROP_LOAD"]:
                    return "older preserved Load was discarded", evidence
            if identity in by_kind["DROP_MDU"]:
                return "older preserved MDU was canceled", evidence
            target = next((a for a in matches("DISPATCH", probe["target_pc"])
                           if a["cycle"] > flush["cycle"] and a["id"] in commits), None)
            if not target:
                continue
            if probe.get("early_resume"):
                target_issue = by_kind["ISSUE"].get(target["id"])
                if not target_issue or not completion or target_issue["cycle"] >= completion["cycle"]:
                    continue
            if probe.get("wrap") and allocation.get("slot", 0) <= by_kind["DISPATCH"][flush["id"]].get("slot", 0):
                continue
            return None, {"older_allocation": allocation, "older_issue": issue, "older_completion": completion,
                          "older_commit": commit, "flush": flush, "branch_commit": branch, "target": target}
    return "required preserved older in-flight/queued work and early recovered execution were not observed", evidence
