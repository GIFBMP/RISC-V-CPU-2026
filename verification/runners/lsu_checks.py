"""Strict execution evidence for ordered memory contexts and Store forwarding."""
from collections import deque


def check_memory_transactions(events):
    """Reject reused identities, reordered responses, and any canceled writeback."""
    pending, requests, responses = deque(), {}, {}
    completions = {f["id"] for k, f in events if k == "COMPLETE"}
    commits = {f["id"] for k, f in events if k == "COMMIT"}
    drops = {f["id"]: f for k, f in events if k == "DROP_LOAD"}
    peak = 0
    # Trace lines from one clock edge are textual diagnostics, not sub-cycle
    # ordering. A response consumes an old request before the new handshake.
    transactions = sorted([(k, f) for k, f in events if k in ("MEM_REQUEST", "MEM_RESPONSE")],
                          key=lambda item: (item[1]["cycle"], item[0] == "MEM_REQUEST"))
    for kind, fields in transactions:
        identity = fields["id"]
        if kind == "MEM_REQUEST":
            if identity in requests:
                return "memory identity requested twice", {}
            if fields["write"] and fields["killed"]:
                return "a killed Store reached the memory interface", {}
            requests[identity] = fields
            pending.append(identity)
            peak = max(peak, len(pending))
        else:
            if not pending or pending.popleft() != identity:
                return "memory response identity differs from oldest accepted request", {}
            request = requests[identity]
            if fields["pc"] != request["pc"] or fields["write"] != request["write"]:
                return "memory response lost original instruction identity", {}
            if request["killed"] and not fields["killed"]:
                return "canceled request became live again", {}
            responses[identity] = fields
            if fields["killed"]:
                if fields["write"] or identity in completions or identity in commits or identity not in drops:
                    return "canceled Load wrote back, committed, or lacked a drain event", {}
    exits = [identity for identity, request in requests.items()
             if request["write"] and request["addr"] == 0x80000000]
    if len(exits) != 1:
        return "expected exactly one accepted exit Store", {}
    exit_cycle = requests[exits[0]]["cycle"]
    if any(requests[identity]["cycle"] < exit_cycle for identity in pending):
        return "an older memory transaction remained outstanding at architectural exit", {}
    return None, {"requests": len(requests), "responses": len(responses),
                  "maximum_accepted_outstanding": peak,
                  "killed_responses": sum(item["killed"] for item in responses.values())}


def check_lsu(probe, events):
    def matches(kind, pc=None):
        return [f for k, f in events if k == kind and (pc is None or f.get("pc") == pc)]

    indexed = {kind: {f["id"]: f for f in matches(kind)}
               for kind in ("DISPATCH", "ISSUE", "COMPLETE", "COMMIT", "LOAD_QUEUE", "MEM_REQUEST", "MEM_RESPONSE", "DROP_LOAD")}
    commits = indexed["COMMIT"]
    kind = probe["kind"]
    evidence = {"kind": kind}
    if kind in ("forward", "unknown_store"):
        queues = matches("LOAD_QUEUE", probe["load_pc"])
        stores = {pc: matches("DISPATCH", pc) for pc in probe.get("store_pcs", [probe.get("store_pc")])}
        for queue in queues:
            identity = queue["id"]
            if identity not in commits:
                continue
            older = [max((item for item in candidates if item["id"] < identity),
                         key=lambda item: item["id"], default=None) for candidates in stores.values()]
            if any(item is None for item in older):
                return "Load lacks the required older Store allocation", evidence
            issues = [indexed["ISSUE"].get(item["id"]) for item in older]
            if any(item is None or item["cycle"] >= queue["cycle"] for item in issues):
                return "Load entered LSU before all older Store addresses and data were known", evidence
            if kind == "forward":
                if queue["mask"] != probe["mask"]:
                    continue
                store_commits = [commits.get(item["id"]) for item in older]
                if any(item is None or item["cycle"] <= queue["cycle"] for item in store_commits):
                    continue
                return None, {**evidence, "load": queue, "older_store_issues": issues,
                              "older_store_commits": store_commits}
            allocation = indexed["DISPATCH"][identity]
            if allocation["cycle"] < issues[0]["cycle"]:
                evidence["witness"] = {"load_dispatch": allocation, "store_issue": issues[0], "load_queue": queue}
        if kind == "unknown_store" and "witness" in evidence:
            return None, evidence
        return "required pending-Store forwarding/bypass or unknown-Store blocking did not occur", evidence
    if kind == "concurrent":
        selected = set(probe["load_pcs"])
        pending = set()
        peak = 0
        for event, fields in sorted(events, key=lambda item: (item[1]["cycle"], item[0] == "MEM_REQUEST")):
            if event == "MEM_RESPONSE":
                pending.discard(fields["id"])
            elif event == "MEM_REQUEST" and fields["pc"] in selected and fields["id"] in commits:
                pending.add(fields["id"])
                if len(pending) > peak:
                    peak = len(pending)
                    evidence["simultaneous_ids"] = sorted(pending)
        evidence["peak"] = peak
        return (None if peak >= probe["minimum"] else "insufficient genuinely accepted simultaneous Load requests"), evidence
    if kind == "younger_store":
        witness = None
        for queue in matches("LOAD_QUEUE", probe["load_pc"]):
            if queue["id"] not in commits:
                continue
            if queue["mask"]:
                return "older Load unexpectedly forwarded from a younger Store", evidence
            younger = min((item for item in matches("DISPATCH", probe["store_pc"]) if item["id"] > queue["id"]),
                          key=lambda item: item["id"], default=None)
            if younger is None or younger["id"] not in commits:
                return "required younger Store did not commit", evidence
            load_commit, store_commit = commits[queue["id"]], commits[younger["id"]]
            if store_commit["cycle"] <= load_commit["cycle"]:
                return "younger Store became irrevocable before older Load retired", evidence
            issue = indexed["ISSUE"].get(younger["id"])
            if issue and issue["cycle"] < queue["cycle"]:
                witness = {"load": queue, "younger_store_issue": issue,
                           "load_commit": load_commit, "store_commit": store_commit}
        if witness:
            return None, {**evidence, **witness}
        return "younger Store did not compute address/data before the older delayed Load", evidence
    if kind == "kill_multiple":
        for flush in matches("FLUSH", probe["branch_pc"]):
            candidates = [item for item in matches("LOAD_QUEUE") if item["pc"] in probe["load_pcs"]
                          and item["id"] > flush["id"] and item["cycle"] < flush["cycle"]]
            killed = []
            for queue in candidates:
                identity = queue["id"]
                response = indexed["MEM_RESPONSE"].get(identity)
                request = indexed["MEM_REQUEST"].get(identity)
                drop = indexed["DROP_LOAD"].get(identity)
                if identity in commits:
                    return "a tested wrong-path Load committed", evidence
                if identity in indexed["COMPLETE"]:
                    # Already-completed speculation is legal. It cannot count
                    # toward the required canceled in-flight contexts; every
                    # selected context still needs killed response + DROP and
                    # no completion (also enforced by transaction invariants).
                    continue
                if response and request and drop and response["killed"] and response["cycle"] >= flush["cycle"]:
                    killed.append({"queue": queue, "request": request, "response": response, "drop": drop})
            accepted = [item for item in killed if item["request"]["cycle"] <= flush["cycle"]]
            if len(killed) < probe["minimum"] or len(accepted) < probe["minimum_accepted_at_flush"]:
                continue
            reused = []
            for item in killed:
                allocation = indexed["DISPATCH"][item["queue"]["id"]]
                for replacement in matches("DISPATCH"):
                    if (replacement["pc"] in probe["replacement_pcs"] and replacement["id"] in commits
                            and replacement["pdst"] == allocation["pdst"] and replacement["pdst"] != 0
                            and flush["cycle"] < replacement["cycle"] < item["response"]["cycle"]):
                        reused.append({"old_allocation": allocation, "replacement": replacement,
                                       "stale_response": item["response"]})
            evidence.update({"flush": flush, "killed": killed, "accepted_at_flush": len(accepted), "reused": reused})
            if probe["require_reuse"] and not reused:
                continue
            return None, evidence
        return "multiple killed accepted/queued Loads and required pre-response PRF reuse were not demonstrated", evidence
    if kind == "retired_store_flush":
        for commit in matches("COMMIT", probe["store_pc"]):
            response = indexed["MEM_RESPONSE"].get(commit["id"])
            if not response:
                continue
            flush = next((item for item in matches("FLUSH", probe["branch_pc"])
                          if commit["cycle"] < item["cycle"] < response["cycle"]), None)
            if flush and not response["killed"]:
                return None, {**evidence, "store_commit": commit, "flush": flush, "store_response": response}
        return "no retired buffered Store remained live across a redirect", evidence
    return f"unknown LSU requirement {kind}", evidence
