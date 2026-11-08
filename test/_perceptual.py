"""Metrics of the perceptual bench (path_perceptual.py), pure: they read the samples the Lua job
returns, nothing else. Thresholds are the audible ones:
a broadband level change of about 1 dB (JND) between two positions is audible.

A walk is a list of samples, one per position, each a dict: level keys ("c" cold, "w" warm, dB)
and direction keys ("d" dominant voice, "s" with the continuous sounds' hysteresis, vectors from
the listener, any length). A sample without a direction (no voice) is left out of the direction
metrics.
"""
import math

JND_DB = 1.0       # broadband level JND (Schaefer et al. 2024; section 6.4)
DIR_JUMP_DEG = 15  # report marker only: no sourced threshold for a step of apparent direction


def angle_deg(a, b):
    """Angle between two 3-vectors in degrees; None when one is missing or null."""
    if a is None or b is None:
        return None
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    if na < 1e-9 or nb < 1e-9:
        return None
    c = sum(x * y for x, y in zip(a, b)) / (na * nb)
    return math.degrees(math.acos(max(-1.0, min(1.0, c))))


def percentile(values, q):
    """sorted[ceil(n q)] (1-based): the convention of path_quality.lua's p90."""
    v = sorted(values)
    if not v:
        return None
    return v[max(0, min(len(v), math.ceil(len(v) * q)) - 1)]


def step_metrics(walks, key="w", dir_key="d", jnd=JND_DB, dir_deg=DIR_JUMP_DEG):
    """Level and direction change between consecutive samples of each walk.
    over_jnd: share of steps whose level changes by more than `jnd` dB; walks_over: share of walks
    with at least one such step; p95 / worst (dB) and worst_at = [walk, step] (step i = sample i to
    i + 1). dir_*: the same for the angle between consecutive directions (degrees), over the steps
    where both samples have one; dir_over: share above `dir_deg`."""
    dl, worst, worst_at, walks_over, n_walks = [], -1.0, None, 0, 0
    da, dworst, dworst_at = [], -1.0, None
    for wi, w in enumerate(walks):
        if len(w) < 2:
            continue
        n_walks += 1
        over = False
        for i in range(len(w) - 1):
            d = abs(w[i + 1][key] - w[i][key])
            dl.append(d)
            if d > jnd:
                over = True
            if d > worst:
                worst, worst_at = d, [wi, i]
            a = angle_deg(w[i].get(dir_key), w[i + 1].get(dir_key))
            if a is not None:
                da.append(a)
                if a > dworst:
                    dworst, dworst_at = a, [wi, i]
        walks_over += over
    if not dl:
        return {"steps": 0}
    out = {"steps": len(dl), "over_jnd": round(sum(d > jnd for d in dl) / len(dl), 3),
           "walks_over": round(walks_over / n_walks, 3), "p95": round(percentile(dl, 0.95), 2),
           "worst": round(worst, 2), "worst_at": worst_at, "dir_steps": len(da)}
    if da:
        out.update({"dir_over": round(sum(a > dir_deg for a in da) / len(da), 3),
                    "dir_p95": round(percentile(da, 0.95), 1), "dir_worst": round(dworst, 1),
                    "dir_worst_at": dworst_at})
    return out


def reciprocity_metrics(pairs, jnd=JND_DB):
    """pairs: (level S -> L, level L -> S) in dB. Shares of |difference| above `jnd` and above 3 dB,
    median, p90, worst and the index of the worst pair."""
    d = [abs(a - b) for a, b in pairs]
    if not d:
        return {"n": 0}
    wi = max(range(len(d)), key=lambda i: d[i])
    return {"n": len(d), "over_jnd": round(sum(x > jnd for x in d) / len(d), 3),
            "over3": round(sum(x > 3 for x in d) / len(d), 3), "median": round(percentile(d, 0.5), 2),
            "p90": round(percentile(d, 0.9), 2), "worst": round(d[wi], 2), "worst_at": wi}


def check(metrics, limits):
    """limits: {(group, metric): max or None}; None = report only. Returns the failures (strings).
    A limit set on a metric that was not measured fails (no data is not a pass)."""
    fails = []
    for (group, name), mx in limits.items():
        if mx is None:
            continue
        v = (metrics.get(group) or {}).get(name)
        if v is None:
            fails.append(f"{group}.{name}: not measured (limit {mx})")
        elif v > mx:
            fails.append(f"{group}.{name} = {v} > {mx}")
    return fails


def _ok(sample):
    return not sample.get("err")


def summarize(v):
    """Metrics of one map's raw job result (path_perceptual.lua). A walk or a reciprocity pair with a
    measure that did not come back (err) is dropped and counted in `errors`. Returns (metrics, kept
    reciprocity pairs)."""
    out = {"pairs": v.get("pairs"), "skipped": v.get("skipped"), "seconds": v.get("seconds")}
    errors = 0
    for who in ("S", "L"):
        walks = []
        for w in v.get("walks" + who) or []:
            if all(_ok(s) for s in w["s"]):
                walks.append(w["s"])
            else:
                errors += 1
        out[who + "_walks"] = len(walks)
        out[who + "_warm"] = step_metrics(walks, key="w", dir_key="d")
        out[who + "_cold"] = step_metrics(walks, key="c", dir_key="d")
        st = step_metrics(walks, key="w", dir_key="s")
        out[who + "_stable"] = {k: st[k] for k in st if k.startswith("dir_")}
    rec = [r for r in v.get("recip") or [] if _ok(r["ab"]) and _ok(r["ba"])]
    errors += len(v.get("recip") or []) - len(rec)
    out["recip_warm"] = reciprocity_metrics([(r["ab"]["w"], r["ba"]["w"]) for r in rec])
    out["recip_cold"] = reciprocity_metrics([(r["ab"]["c"], r["ba"]["c"]) for r in rec])
    out["errors"] = errors
    return out, rec


def details(v, out, rec):
    """Where the worst warm level step, the worst stable direction jump and the worst warm reciprocity
    gap are: walk start S / L, heading, step index, the two samples."""
    d = {}
    for who in ("S", "L"):
        walks = [w for w in v.get("walks" + who) or [] if all(_ok(s) for s in w["s"])]
        for name, grp, key in (("level", who + "_warm", "worst_at"), ("dir", who + "_stable", "dir_worst_at")):
            at = out[grp].get(key)
            if at:
                w = walks[at[0]]
                d[f"{who}_{name}"] = {"S": w["S"], "L": w["L"], "dir": w["dir"], "step": at[1],
                                      "from": w["s"][at[1]], "to": w["s"][at[1] + 1]}
    at = out["recip_warm"].get("worst_at")
    if at is not None:
        d["recip"] = rec[at]
    return d
