"""V7 selection, Store-data ownership and retry evidence, keyed by dynamic ID."""
from collections import Counter, defaultdict
from bisect import bisect_left


def instruction_class(insn):
    opcode = insn & 0x7f
    if opcode == 0x03:
        return "load"
    if opcode == 0x23:
        return "store"
    if opcode in (0x63, 0x67, 0x6f):
        return "control"
    if opcode == 0x33 and insn >> 25 == 1:
        return "mdu"
    return "integer"


def index_events(events):
    indexed = defaultdict(lambda: defaultdict(list))
    for kind, fields in events:
        indexed[kind][fields["id"]].append(fields)
    return indexed


def check_v7_invariants(events):
    configs = [f for k, f in events if k == "CONFIG" and f.get("version") == 7]
    if not configs:
        return None, {"applicable": False}
    cfg = configs[0]
    idx = index_events(events)
    producer_ids = defaultdict(list)
    for identity in sorted(idx["DISPATCH"]):
        allocation = idx["DISPATCH"][identity][0]
        if allocation.get("pdst"):
            producer_ids[allocation["pdst"]].append(identity)
    proof = {"applicable": True, "selections": 0, "retries": 0, "late_store_data": 0,
             "fast_loads": 0, "maximum_execution_accepts": 0}
    cycles = defaultdict(list)
    for kind, fields in events:
        cycles[fields["cycle"]].append((kind, fields))
    stores = {}
    for cycle, group in sorted(cycles.items()):
        for kind, fields in group:
            if kind == "FLUSH":
                stores = {i:s for i,s in stores.items() if fields.get("selective") and i <= fields["id"]}
        # Read the pre-edge state: same-cycle Store retirement/data capture
        # takes effect after a Load has used its saved older-Store snapshot.
        for kind, fields in group:
            if kind != "LOAD_QUEUE":
                continue
            mask, data = 0, 0
            for identity, state in sorted(stores.items()):
                if identity >= fields["id"]:
                    continue
                addr = state.get("address")
                if not addr:
                    return f"Load passed an unknown older Store address at cycle {cycle}", proof
                if addr["addr"] != fields["addr"]:
                    continue
                if "data" not in state:
                    return f"Load passed unknown aliasing Store data at cycle {cycle}", proof
                for byte in range(4):
                    if addr["strb"] & (1 << byte):
                        lane = 255 << (byte * 8)
                        mask |= 1 << byte
                        data = (data & ~lane) | (state["data"]["data"] & lane)
            byte_mask = sum(255 << (8 * b) for b in range(4) if mask & (1 << b))
            if fields["mask"] != mask or (fields["data"] & byte_mask) != data:
                return f"Load forwarding differs from youngest older Store bytes at cycle {cycle}", proof
        for kind, fields in group:
            identity = fields["id"]
            if kind == "DISPATCH" and instruction_class(fields["insn"]) == "store":
                stores[identity] = {}
            elif kind in ("STORE_ADDR", "STORE_DATA"):
                if identity not in stores:
                    return f"Store payload without live allocation at cycle {cycle}", proof
                stores[identity]["address" if kind == "STORE_ADDR" else "data"] = fields
            elif kind == "STORE_RETIRE":
                stores.pop(identity, None)
    for kind, width in (("DISPATCH", "rename_width"), ("SELECT", "select_width"), ("COMMIT", "commit_width")):
        groups = defaultdict(list)
        for rows in idx[kind].values():
            for row in rows:
                groups[row["cycle"]].append(row)
        for cycle, rows in groups.items():
            if len(rows) > cfg[width] or len({r["id"] for r in rows}) != len(rows):
                return f"{kind} exceeds width or repeats an ID at cycle {cycle}", proof
            if kind == "SELECT" and (len({r["lane"] for r in rows}) != len(rows)
                                     or any(r["lane"] >= cfg[width] for r in rows)):
                return f"SELECT lane collision at cycle {cycle}", proof
        proof[kind.lower() + "_maximum"] = max(map(len, groups.values()), default=0)
    accepts = Counter(f["cycle"] for rows in idx["ISSUE"].values() for f in rows)
    proof["maximum_execution_accepts"] = max(accepts.values(), default=0)
    # ISSUE records acceptance by variable pipeline stages. Width is enforced
    # on SELECT, while every accepted operation must still execute exactly once.
    for kind in ("DISPATCH", "ISSUE", "COMPLETE", "COMMIT", "STORE_ADDR", "STORE_DATA", "LOAD_QUEUE"):
        if any(len(rows) != 1 for rows in idx[kind].values()):
            return f"duplicate {kind} for one dynamic ID", proof
    for identity, selections in idx["SELECT"].items():
        allocation = idx["DISPATCH"].get(identity, [])
        if not allocation or any(s["cycle"] <= allocation[0]["cycle"]
                                 or s["pc"] != allocation[0]["pc"] for s in selections):
            return f"SELECT has no preceding allocation for id={identity}", proof
        selections = sorted(selections, key=lambda s: s["cycle"])
        for selection in selections:
            cls = instruction_class(selection["insn"])
            if cfg["select_width"] == 2 and ((selection["lane"] == 1 and cls not in ("integer", "control"))
                                            or (selection["lane"] == 0 and cls == "control")):
                return f"instruction selected on an incompatible lane for id={identity}", proof
        retries = idx["LOAD_RETRY"].get(identity, [])
        for previous, current in zip(selections, selections[1:]):
            if (instruction_class(current["insn"]) != "load"
                    or not any(previous["cycle"] < r["cycle"] < current["cycle"] for r in retries)):
                return f"reselection without an intervening Load retry for id={identity}", proof
        proof["selections"] += len(selections)
    for identity, rows in idx["ISSUE"].items():
        accepted = rows[0]
        selections = idx["SELECT"].get(identity, [])
        if not selections or selections[-1]["cycle"] > accepted["cycle"]:
            return f"execution without a selection for id={identity}", proof
        last = selections[-1]
        if last["cycle"] == accepted["cycle"] and not last.get("fast"):
            return f"same-cycle execution without early Load for id={identity}", proof
        if last.get("fast"):
            queues = idx["LOAD_QUEUE"].get(identity, [])
            if instruction_class(last["insn"]) != "load" or not queues or queues[0]["cycle"] != last["cycle"]:
                return f"early Load lacks its unique descriptor for id={identity}", proof
            proof["fast_loads"] += 1
    for identity, rows in idx["LOAD_RETRY"].items():
        selections = idx["SELECT"].get(identity, [])
        if not selections or any(not any(s["cycle"] < r["cycle"] for s in selections) for r in rows):
            return f"retry without an earlier selection for id={identity}", proof
        accepted = idx["ISSUE"].get(identity, [])
        if accepted and any(r["cycle"] >= accepted[0]["cycle"] for r in rows):
            return f"Load retried after acceptance for id={identity}", proof
        proof["retries"] += len(rows)
    for identity, rows in idx["STORE_DATA"].items():
        data = rows[0]
        addresses = idx["STORE_ADDR"].get(identity, [])
        if not addresses or addresses[0]["cycle"] > data["cycle"] or addresses[0]["psrc"] != data["psrc"]:
            return f"Store data lacks its address/source ownership for id={identity}", proof
        addr = addresses[0]
        if bool(data["late"]) != (data["cycle"] > addr["cycle"]) or bool(data["late"]) == bool(addr["ready"]):
            return f"inconsistent Store readiness for id={identity}", proof
        if data["late"]:
            owners = producer_ids[data["psrc"]]
            previous = bisect_left(owners, identity) - 1
            complete = idx["COMPLETE"].get(owners[previous], []) if previous >= 0 else []
            if not complete or complete[0]["cycle"] != data["cycle"]:
                return f"late Store captured without its producer completion for id={identity}", proof
            proof["late_store_data"] += 1
    for identity, rows in idx["COMMIT"].items():
        commit = rows[0]
        if not idx["ISSUE"].get(identity):
            return f"commit without execution for id={identity}", proof
        if commit.get("store"):
            addresses, data = idx["STORE_ADDR"].get(identity, []), idx["STORE_DATA"].get(identity, [])
            if not addresses or not data or data[0]["cycle"] >= commit["cycle"]:
                return f"Store retired before address and data were ready for id={identity}", proof
            mask = sum(255 << (8 * b) for b in range(4) if commit["strb"] & (1 << b))
            if (commit["addr"] != addresses[0]["addr"] or commit["strb"] != addresses[0]["strb"]
                    or (commit["data"] & mask) != (data[0]["data"] & mask)):
                return f"Store payload changed between capture and commit for id={identity}", proof
        elif not idx["COMPLETE"].get(identity) or idx["COMPLETE"][identity][0]["cycle"] >= commit["cycle"]:
            return f"commit before completion for id={identity}", proof
    return None, proof


def check_v7_probe(probe, events):
    idx = index_events(events)
    committed = set(idx["COMMIT"])
    def matching(kind, pc):
        return [f for rows in idx[kind].values() for f in rows if f["pc"] == pc and f["id"] in committed]
    kind = probe["kind"]
    if kind == "late_store":
        for addr in matching("STORE_ADDR", probe["store_pc"]):
            data = idx["STORE_DATA"].get(addr["id"], [{}])[0]
            if addr["ready"] or not data.get("late"):
                continue
            producer = next((p for p in matching("ISSUE", probe["producer_pc"])
                             if p["id"] < addr["id"] and addr["cycle"] < p["cycle"] < data["cycle"]), None)
            queue = next((q for q in matching("LOAD_QUEUE", probe["load_pc"]) if q["id"] > addr["id"]), None)
            if not producer or not queue:
                continue
            retries = idx["LOAD_RETRY"].get(queue["id"], [])
            if probe["alias"]:
                if not retries or queue["cycle"] <= data["cycle"] or queue["addr"] != addr["addr"]:
                    continue
            elif not addr["cycle"] < queue["cycle"] < data["cycle"] or queue["mask"] or queue["addr"] == addr["addr"]:
                continue
            return None, {"address": addr, "producer": producer, "data": data, "load": queue, "retries": retries[:2]}
        return "no late Store data / queued producer / alias retry or nonalias bypass witness", {}
    if kind == "pairs":
        proof = {}
        for event, requirements in probe["pairs"].items():
            groups = defaultdict(list)
            for identity, rows in idx[event].items():
                if identity in committed:
                    for row in rows:
                        groups[row["cycle"]].append(row)
            for name in requirements:
                classes = name.split("+")
                witness = next((sorted(rows, key=lambda r: r["id"]) for rows in groups.values()
                                if len(rows) == 2 and [instruction_class(r["insn"]) for r in sorted(rows, key=lambda r: r["id"])] == classes), None)
                if not witness:
                    return f"missing genuine {event} pair {name}", proof
                proof[event + ":" + name] = witness
        return None, proof
    if kind == "second_checkpoint":
        proof = {}
        for flush in [f for rows in idx["FLUSH"].values() for f in rows if f["id"] in committed]:
            branch = idx["DISPATCH"][flush["id"]][0]
            if instruction_class(branch["insn"]) != "control":
                continue
            first = idx["DISPATCH"].get(branch["id"] - 1, [])
            if first and first[0]["cycle"] == branch["cycle"] and first[0]["id"] in committed:
                a = first[0]
                if a.get("rd") and a["rd"] == branch.get("rd") == (branch["insn"] >> 15) & 31:
                    proof["raw_waw_link"] = {"first": a, "second": branch, "flush": flush}
                elif a.get("rd") and a["rd"] != branch.get("rd"):
                    proof["first_mapping_and_link"] = {"first": a, "second": branch, "flush": flush}
        return (None if len(proof) == 2 else "second-position checkpoint lacks both mapping/link hazards"), proof
    if kind == "retry_recovery":
        for load in matching("COMMIT", probe["load_pc"]):
            identity = load["id"]
            for flush in matching("FLUSH", probe["branch_pc"]):
                if identity >= flush["id"] or load["cycle"] <= flush["cycle"]:
                    continue
                retries = [r for r in idx["LOAD_RETRY"].get(identity, []) if r["cycle"] < flush["cycle"]]
                resumed = [s for s in idx["SELECT"].get(identity, []) if s["cycle"] > flush["cycle"]]
                if retries and resumed and len(idx["ISSUE"][identity]) == 1 and len(idx["COMPLETE"][identity]) == 1:
                    return None, {"retry": retries[0], "flush": flush, "resumed": resumed[0], "commit": load}
        return "older Load did not retain its retry identity across recovery", {}
    if kind == "keep_execution":
        for identity, rows in idx["EX_KEEP"].items():
            if identity not in committed:
                continue
            for kept in rows:
                flush = next((f for values in idx["FLUSH"].values() for f in values
                              if f["cycle"] == kept["cycle"] and f.get("selective") and f["id"] > identity), None)
                allocation = idx["DISPATCH"].get(identity, [])
                selected = idx["SELECT"].get(identity, [])
                issued, completed, retired = (idx[event].get(identity, [])
                                              for event in ("ISSUE", "COMPLETE", "COMMIT"))
                if (flush and len(allocation) == len(issued) == len(completed) == len(retired) == 1
                        and allocation[0]["pc"] == kept["pc"] and allocation[0]["insn"] == kept["insn"]
                        and any(allocation[0]["cycle"] < s["cycle"] < kept["cycle"] for s in selected)
                        and kept["cycle"] < issued[0]["cycle"] <= completed[0]["cycle"] < retired[0]["cycle"]):
                    return None, {"kept": kept, "flush": flush, "issue": issued[0],
                                  "complete": completed[0], "commit": retired[0]}
        return "no surviving old EX operation held at recovery and uniquely completed afterwards", {}
    if kind == "cancel_store_data":
        for rows in idx["STORE_ADDR"].values():
            addr = rows[0]
            if addr["pc"] != probe["store_pc"] or addr["ready"] or addr["id"] in committed:
                continue
            for flush in matching("FLUSH", probe["branch_pc"]):
                producer = next((p for p in matching("COMPLETE", probe["producer_pc"])
                                 if p["id"] < flush["id"] and p["cycle"] > flush["cycle"]), None)
                allocation = idx["DISPATCH"].get(addr["id"], [{}])[0]
                reused = next((rows[0] for rows in idx["DISPATCH"].values() if producer
                               and rows[0]["id"] > addr["id"] and rows[0].get("slot") == allocation.get("slot")
                               and flush["cycle"] < rows[0]["cycle"] < producer["cycle"]), None)
                if (producer and addr["id"] > flush["id"] and addr["cycle"] < flush["cycle"]
                        and reused and not idx["STORE_DATA"].get(addr["id"])):
                    return None, {"address": addr, "flush": flush, "surviving_producer": producer, "reused_slot": reused}
        return "missing canceled address-ready Store, slot reuse and producer completion after recovery", {}
    return f"unknown V7 probe {kind}", {}
