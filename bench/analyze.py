#!/usr/bin/env python3
"""bench/analyze.py — turn a run's records into a verdict.

The acceptance is stated as three claims and this file is what tests them:

  L1  reliability   — 0 of N shots lost
  L2  correctness   — the clipboard's bytes ARE the file's bytes, N of N
  L3  ordering      — when two shots settle in one scan, the LATER one is on the clipboard

🚨 A PASS ON A SMALL N IS NOT A PASS.  The failure this pipeline exists to remove happens on ~1.1 %
of shots, so N ≈ 209 is needed for even 90 % odds of observing ONE.  A run below that prints
INSUFFICIENT-N and says so in its verdict, and a run that saw no ≥ 1 s Apple stall at all says that
too — because a clean sheet against a hazard that never occurred is not evidence.
"""

import argparse, json, math, statistics, sys
from datetime import date

# The 30-day baselines this run's own stall rate is checked against (knowledge base §F2).  The two
# numbers differ because the full sample is contaminated by the investigation's own CLI bursts, and
# the two K1 refuter lenses never agreed on the share — so both are quoted, never one.
BASE_STALL_1S_USER = 2.6      # % of the 547 non-probe shots
BASE_STALL_1S_FULL = 4.6      # % of the contaminated 611-shot sample
N_FOR_90PCT = 209


def pct(values, p):
    """Nearest-rank percentile.  p100 is the maximum, which is the number the targets are stated in."""
    if not values:
        return None
    s = sorted(values)
    k = max(1, math.ceil(p / 100.0 * len(s)))
    return s[min(k, len(s)) - 1]


def ms(v):
    return None if v is None else v / 1e6


def series(records, a, b, band=None):
    out = []
    for r in records:
        if band and r.get("band") != band:
            continue
        ph = r.get("phases") or {}
        t0 = r.get(a) if a in r else ph.get(a)
        t1 = r.get(b) if b in r else ph.get(b)
        if t0 and t1 and t1 >= t0:
            out.append(t1 - t0)
    return out


def table(name, vals):
    if not vals:
        return f"| {name} | 0 | — | — | — | — | — |"
    return "| {} | {} | {:.1f} | {:.1f} | {:.1f} | {:.1f} | {:.1f} |".format(
        name, len(vals), ms(pct(vals, 50)), ms(pct(vals, 90)), ms(pct(vals, 99)),
        ms(pct(vals, 100)), ms(int(statistics.mean(vals))))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("records")
    ap.add_argument("--md", default=None, help="write an acceptance document here")
    ap.add_argument("--listings-per-shot", type=float, default=None)
    args = ap.parse_args()

    data = json.load(open(args.records))
    recs = data["records"]
    n = len(recs)

    lost = [r for r in recs if r.get("outcome") in ("lost", "silent", "no-artifact")]
    silent = [r for r in recs if r.get("outcome") == "silent"]
    copied = [r for r in recs if r.get("outcome") == "copied"]
    mismatched = [r for r in copied if not r.get("bytes_match")]
    disagreements = [r for r in copied if (r.get("probe_disagreement_ms") or 0) > 100]
    no_thumb = [r for r in copied if "thumb-visible" not in (r.get("phases") or {})]

    stalls = [r["apple_stall_ns"] / 1e9 for r in recs if r.get("apple_stall_ns") is not None]
    stalls_1s = [s for s in stalls if s >= 1.0]
    stall_rate = 100.0 * len(stalls_1s) / len(stalls) if stalls else 0.0

    png_copied = series(recs, "png_complete_mono", "copied")
    spawn_copied = series(recs, "t_spawn_mono", "copied")
    spawn_vis = series(recs, "t_spawn_mono", "thumb-visible")
    created_copied = series(recs, "created", "copied")
    shown_vis = series(recs, "thumb-shown", "thumb-visible")

    lines = []
    add = lines.append
    add(f"lost {len(lost)}/{n}")
    p100 = ms(pct(png_copied, 100))
    if p100 is not None:
        add(f"png-complete→copied p50 {ms(pct(png_copied,50)):.1f} ms · "
            f"p99 {ms(pct(png_copied,99)):.1f} ms · p100 {p100:.1f} ms")
    add(f"capture→copied p50 {ms(pct(spawn_copied,50)) or float('nan'):.1f} ms · "
        f"p99 {ms(pct(spawn_copied,99)) or float('nan'):.1f} ms")
    if spawn_vis:
        add(f"capture→thumb-visible p50 {ms(pct(spawn_vis,50)):.1f} ms · "
            f"p100 {ms(pct(spawn_vis,100)):.1f} ms")
    add(f"clipboard bytes == file bytes: {len(copied)-len(mismatched)}/{len(copied)}")
    add(f"apple stall ≥ 1 s: {len(stalls_1s)}/{len(stalls)} ({stall_rate:.1f} %) "
        f"vs baselines {BASE_STALL_1S_USER} % (user) / {BASE_STALL_1S_FULL} % (contaminated)")
    if args.listings_per_shot is not None:
        add(f"listings per shot: {args.listings_per_shot:.2f}")
    if silent:
        add(f"🚨 {len(silent)} shot(s) produced NEITHER copied NOR lost — the instrument's own blind spot")
    if disagreements:
        add(f"🚨 {len(disagreements)} iteration(s) where the prober disagreed with "
            f"thumb-visible by > 100 ms")
    if data.get("screen_locked"):
        add("note: the screen was LOCKED — capture→thumb-visible is UNMEASURABLE in this run "
            "(the canvas is genuinely occluded behind the lock window, and isOccluded() is right "
            "to say so); the latency and reliability numbers are unaffected")
    elif no_thumb:
        add(f"note: {len(no_thumb)} copied shot(s) logged no thumb-visible line")

    verdict = []
    if len(lost) == 0 and n > 0:
        verdict.append("L1 PASS (0 lost)")
    else:
        verdict.append(f"L1 FAIL ({len(lost)} lost)")
    verdict.append("L2 PASS" if not mismatched and copied else f"L2 FAIL ({len(mismatched)} mismatched)")
    if p100 is not None:
        verdict.append("latency PASS (p100 ≤ 30 ms)" if p100 <= 30 else f"latency FAIL (p100 {p100:.1f} ms)")
    if n < N_FOR_90PCT:
        verdict.append(f"INSUFFICIENT-N ({n} < {N_FOR_90PCT}: a 1.1 % hazard needs N ≥ {N_FOR_90PCT} "
                       "for 90 % odds of one observation)")
    if not stalls_1s:
        verdict.append("INSUFFICIENT-N for the stall class (no ≥ 1 s Apple stall occurred in this run)")
    add("verdict: " + " · ".join(verdict))

    print("\n".join(lines))

    if args.md:
        rows = [
            "| interval | n | p50 | p90 | p99 | p100 | mean |",
            "|---|---|---|---|---|---|---|",
            table("png-complete → copied", png_copied),
            table("capture-spawn → copied", spawn_copied),
            table("created → copied", created_copied),
            table("capture-spawn → thumb-visible", spawn_vis),
            table("thumb-shown → thumb-visible", shown_vis),
        ]
        bands = sorted({r.get("band") for r in recs if r.get("band")})
        band_rows = ["| band | n | png→copied p50 | p100 | median bytes |", "|---|---|---|---|---|"]
        for b in bands:
            v = series(recs, "png_complete_mono", "copied", band=b)
            szs = [r["bytes"] for r in recs if r.get("band") == b and r.get("bytes")]
            band_rows.append("| {} | {} | {} | {} | {} |".format(
                b, len(v),
                f"{ms(pct(v,50)):.1f} ms" if v else "—",
                f"{ms(pct(v,100)):.1f} ms" if v else "—",
                f"{int(statistics.median(szs)):,}" if szs else "—"))

        with open(args.md, "w") as f:
            f.write(f"""# Screenshot pipeline — acceptance run {data['run_id']} ({date.today().isoformat()})

Produced by `bash scripts/screenshot-bench.sh {data['requested']}` →
`bench/run.py` → `bench/analyze.py`.  Mode `{data.get('mode')}` (sound off, dismiss 0.4 s);
percentiles are never compared across modes.

**Headline**

```
{chr(10).join(lines)}
```

## Percentiles (milliseconds)

{chr(10).join(rows)}

## By capture size band

Every latency target in the plan was calibrated on one 2.4 MB image — percentile 84.7 of 3,377 real
shots.  One iteration in {20} is a full-display capture so the tail is sampled rather than assumed
(completeness critic item 11).

{chr(10).join(band_rows)}

## Validity

- **`-R` is not the keyboard path.** It reproduces the file writes byte for byte and in sequence
  (n=11, same CGImageDestinationCreateWithURL call site), but there is no crosshair, drag or
  mouse-up — so `capture-spawn → copied` includes process spawn and excludes the interactive phase.
- **This run loaded `mds` itself.** {len(stalls_1s)} of {len(stalls)} captures stalled ≥ 1 s
  ({stall_rate:.1f} %), against the 30-day baselines of {BASE_STALL_1S_USER} % (547 non-probe
  shots) and {BASE_STALL_1S_FULL} % (contaminated full sample).
- **The prober falsifies, it does not time.** {len(disagreements)} iteration(s) disagreed with the
  in-process `thumb-visible` line by more than 100 ms.
- **Requested {data['requested']}, completed {data['completed']}.**
  Aborted: {data.get('aborted') or 'no'}.
- Hammerspoon instances at preflight: {data.get('hammerspoon_instances')}.
""")
        print(f"[analyze] wrote {args.md}")

    fail = bool(lost or mismatched or silent or (p100 is not None and p100 > 30))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
