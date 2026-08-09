#!/usr/bin/env python3
"""Build ZoiaCanvas ModuleCatalog.json.

Merges three sources:
  A. zoia_lib ModuleIndex.json      — binary truth: type IDs, option byte order
                                      (dict insertion order), params, cpu
  B. zoia_lib_macOS ordered index   — deterministic block order (arrays),
                                      options keyed by numeric position
  C. Empress fw5 module-index CSV   — human docs: descriptions, knob functions,
                                      typical connections, option descriptions
"""
import csv
import json
import re
import sys
from pathlib import Path

SCRATCH = Path(__file__).parent
REFS = SCRATCH / "refs"
A_PATH = REFS / "zoia_lib/zoia_lib/common/schemas/ModuleIndex.json"
B_PATH = REFS / "zoia_lib_macOS/ZoiaLibMac/ZoiaLibMac/Resources/module_index_ordered.json"
C_PATH = Path("/Users/rashford/Library/CloudStorage/Dropbox/Claude Cowork/Songwriting/Manuals/Pedals/empress-effects-zoia-module-index-firmware5.csv")
OUT = Path("/Users/rashford/Developer/zoia-canvas/Sources/ZoiaCanvas/Resources/ModuleCatalog.json")

index_a = json.load(open(A_PATH))          # insertion order preserved
index_b = json.load(open(B_PATH))


def norm(name):
    return re.sub(r"[^a-z0-9]+", "", name.lower())


# ---- Source C: parse the Empress CSV (same structure as gen_zoia_md.py) ----
def clean(s):
    return " ".join(s.split())


docs = {}  # norm(name) -> doc dict
rows = list(csv.reader(open(C_PATH)))
cur_mod = None
after_blank = False
for r in rows[1:]:
    c = [clean(x) for x in r]
    if not any(c):
        after_blank = True
        continue
    if c[1].endswith(":"):
        cur_mod = None
        after_blank = False
        continue
    if c[2] and c[3]:
        cur_mod = {"description": "", "avgDSP": c[11], "blocks": [], "options": {}, "notes": []}
        docs[norm(c[2])] = cur_mod
        target = cur_mod["blocks"]
        if c[4]:
            target.append({"num": c[4], "name": c[5], "knob": c[6], "function": c[7], "connectsTo": c[8]})
        if c[9]:
            cur_mod["options"][c[9]] = c[10]
        after_blank = False
        continue
    if cur_mod is not None:
        if after_blank and (c[4] or c[5]):
            target = cur_mod["blocks"]  # alternate layouts share one doc list; num restarts mark them
        after_blank = False
        if c[2] and not cur_mod["description"]:
            cur_mod["description"] = c[2]
        if c[4] or c[5]:
            target.append({"num": c[4], "name": c[5], "knob": c[6], "function": c[7], "connectsTo": c[8]})
        if c[9]:
            cur_mod["options"][c[9]] = c[10]
        elif c[10]:
            cur_mod["notes"].append(c[10])
        if c[11] and not cur_mod["avgDSP"]:
            cur_mod["avgDSP"] = c[11]

# ---- Merge ----
modules = []
diffs = []
unmatched_docs = set(docs)
for mid in sorted(index_a, key=int):
    a = index_a[mid]
    b = index_b.get(mid, {})

    # option order: zoia_lib insertion order is binary truth; cross-check vs B
    opts_a = [{"key": k, "values": v} for k, v in a.get("options", {}).items()]
    if b.get("options"):
        b_opts = [list(entry.keys())[0] for entry in b["options"]]
        if b_opts != [o["key"] for o in opts_a]:
            diffs.append(f"id {mid} {a['name']}: option order A={[o['key'] for o in opts_a]} B={b_opts}")

    # blocks: order from B's array; props (incl. port `type`) enriched from A,
    # matching by exact name then by normalized name
    a_blocks = a.get("blocks", {})
    a_by_norm = {norm(k): v for k, v in a_blocks.items()}
    if b.get("blocks"):
        blocks = []
        for entry in b["blocks"]:
            (bname, props), = entry.items()
            enrich = a_blocks.get(bname) or a_by_norm.get(norm(bname)) or {}
            if not enrich and "position" in props:  # renamed across firmware; match by grid position
                enrich = next((v for v in a_blocks.values() if v.get("position") == props["position"]), {})
            merged = {**enrich, **props}
            if "type" not in merged:
                diffs.append(f"id {mid} {a['name']}: block {bname} has no port type")
            blocks.append({"key": bname, **{k: merged[k] for k in ("isDefault", "isParam", "position", "type") if k in merged}})
    else:
        blocks = [{"key": k, **v} for k, v in sorted(a_blocks.items(), key=lambda kv: kv[1].get("position", 0))]
        diffs.append(f"id {mid} {a['name']}: no ordered blocks in B, used A positions")

    dkey = norm(a["name"])
    # Euroburo per-jack modules share the sheet's generic CV In / CV Out docs
    if dkey not in docs:
        m = re.match(r"^(eurocvin|eurocvout)\d$", dkey)
        if m:
            dkey = m.group(1).replace("euro", "")
    doc = docs.get(dkey)
    if doc:
        unmatched_docs.discard(dkey)

    modules.append({
        "id": int(mid),
        "name": a["name"],
        "category": a.get("category", ""),
        "cpu": a.get("cpu", 0),
        "paramCount": a.get("params", 0),
        "minBlocks": a.get("min_blocks", 0),
        "maxBlocks": a.get("max_blocks", 0),
        "defaultBlocks": a.get("default_blocks", 0),
        "blocks": blocks,
        "options": opts_a,
        "paramDefaults": a.get("param_defaults", {}),
        "doc": doc,
    })

def sanitize(o):
    """Strict JSON has no Infinity/NaN; encode them as strings ("inf"/"-inf")."""
    if isinstance(o, float) and (o != o or o in (float("inf"), float("-inf"))):
        return "nan" if o != o else ("inf" if o > 0 else "-inf")
    if isinstance(o, dict):
        return {k: sanitize(v) for k, v in o.items()}
    if isinstance(o, list):
        return [sanitize(v) for v in o]
    return o


json.dump(sanitize({"formatVersion": 1, "modules": modules}), open(OUT, "w"),
          indent=1, allow_nan=False)

with_doc = sum(1 for m in modules if m["doc"])
print(f"modules: {len(modules)}, with docs: {with_doc}, without: {[m['name'] for m in modules if not m['doc']]}")
print(f"unmatched doc names: {sorted(unmatched_docs)}")
print(f"diffs: {len(diffs)}")
for d in diffs[:15]:
    print(" ", d)
