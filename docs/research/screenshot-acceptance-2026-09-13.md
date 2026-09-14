# Screenshot pipeline — acceptance run ebd628a7 (2026-09-13)

Produced by `bash scripts/screenshot-bench.sh 300` →
`bench/run.py` → `bench/analyze.py`.  Mode `bench` (sound off, dismiss 0.4 s);
percentiles are never compared across modes.

**Headline**

```
lost 0/197
png-complete→copied p50 20.8 ms · p99 34.2 ms · p100 38.3 ms
capture→copied p50 420.0 ms · p99 664.5 ms
clipboard bytes == file bytes: 197/197
apple stall ≥ 1 s: 0/197 (0.0 %) vs baselines 2.6 % (user) / 4.6 % (contaminated)
listings per shot: 4.30
note: the screen was LOCKED — capture→thumb-visible is UNMEASURABLE in this run (the canvas is genuinely occluded behind the lock window, and isOccluded() is right to say so); the latency and reliability numbers are unaffected
verdict: L1 PASS (0 lost) · L2 PASS · latency FAIL (p100 38.3 ms) · INSUFFICIENT-N (197 < 209: a 1.1 % hazard needs N ≥ 209 for 90 % odds of one observation) · INSUFFICIENT-N for the stall class (no ≥ 1 s Apple stall occurred in this run)
```

## Percentiles (milliseconds)

| interval | n | p50 | p90 | p99 | p100 | mean |
|---|---|---|---|---|---|---|
| png-complete → copied | 197 | 20.8 | 25.5 | 34.2 | 38.3 | 21.0 |
| capture-spawn → copied | 197 | 420.0 | 522.0 | 664.5 | 804.6 | 413.4 |
| created → copied | 197 | 286.0 | 366.6 | 496.7 | 658.7 | 284.2 |
| capture-spawn → thumb-visible | 0 | — | — | — | — | — |
| thumb-shown → thumb-visible | 0 | — | — | — | — | — |

## Where the time goes

| component | n | p50 | p90 | p100 |
|---|---|---|---|---|
| read the PNG through the open handle | 197 | 10.72 ms | 14.32 ms | 19.44 ms |
| hs.pasteboard.writeAllData (general board) | 197 | 3.05 ms | 7.72 ms | 22.53 ms |
| readDataForUTI read-back (the L2 proof) | 197 | 1.65 ms | 4.90 ms | 10.87 ms |

## By capture size band

Every latency target in the plan was calibrated on one 2.4 MB image — percentile 84.7 of 3,377 real
shots.  One iteration in 20 is a full-display capture so the tail is sampled rather than assumed
(completeness critic item 11).

| band | n | png→copied p50 | p100 | median bytes |
|---|---|---|---|---|
| base | 188 | 20.5 ms | 34.2 ms | 8,108,469 |
| full | 9 | 24.7 ms | 38.3 ms | 12,595,661 |

## Validity

- **`-R` is not the keyboard path.** It reproduces the file writes byte for byte and in sequence
  (n=11, same CGImageDestinationCreateWithURL call site), but there is no crosshair, drag or
  mouse-up — so `capture-spawn → copied` includes process spawn and excludes the interactive phase.
- **This run loaded `mds` itself.** 0 of 197 captures stalled ≥ 1 s
  (0.0 %), against the 30-day baselines of 2.6 % (547 non-probe
  shots) and 4.6 % (contaminated full sample).
- **The prober falsifies, it does not time.** 0 iteration(s) disagreed with the
  in-process `thumb-visible` line by more than 100 ms.
- **Requested 300, completed 197.**
  Aborted: operator returned at iteration 197 (idle 1.0s).
- Hammerspoon instances at preflight: 1.

---

## Verdict against the plan's target table — read this before the numbers above

*(Integrated by hand after the generated run; everything above is `analyze.py`'s output verbatim.)*

| plan target | measured | verdict |
|---|---|---|
| 0 of N lost (**L1**) | **0 of 197** | ✅ |
| clipboard bytes == file bytes, N of N (**L2**) | **197 of 197** | ✅ |
| the later of two same-scan shots wins (**L3**) | not exercised — the bench spaces captures ≥ 2 s by design, so two never settle in one scan | ⚪ unexercised; the mechanism is the ascending-`seq` sort in `settleTick` and `last_copied_seq` in `hsc()` makes it observable |
| PNG-complete → clipboard **≤ 15 ms p50, ≤ 30 ms p100** | **20.8 p50 / 34.2 p99 / 38.3 p100** | ❌ **at this capture size** — see below |
| capture (mouse-up) → clipboard ≤ 70 ms p50, ≤ 250 ms p99 | 420 / 664 ms, but the interval measured is `capture-SPAWN → copied` and includes a `screencapture` fork/exec plus Apple's write of an 8–12 MB PNG | ⚪ not comparable; the keyboard path has no spawn |
| capture → thumbnail fully visible ≤ 200 ms p50 | **unmeasurable by an unattended run** (the 180 s idle gate is what locks the screen) | ⚪ see § What would close the two open rows |
| 0 listings without a size change | **1.00/s idle** (the backstop alone) and **4.30 per shot** under bench load | ✅ inside the decision log's budget |

### 🚨 The p100 miss is a SIZE mismatch, and the bench's own precondition caused it

Every latency target in the plan derives from one 2 516 × 1 926 / **2.4 MB** capture — percentile
84.7 of 3 377 real shots. **This run's median capture is 8.1 MB, and the full-display band is
12.6 MB**: 3.4× and 5.2× the calibration image. The reason is the gate, not the geometry — 180 s of
idle is exactly what puts this Mac on its lock screen, and the lock wallpaper is a photograph, which
compresses to roughly three times what a UI screenshot of the same rectangle does. **The unattended
bench therefore samples the pessimistic end of the real size distribution by construction.**

The cost table above shows where that lands: **reading the PNG is 10.72 ms p50 / 19.44 ms p100**,
the single largest term, and it scales with bytes. The two measured bands give the slope directly —
8.1 MB → 20.5 ms p50 and 12.6 MB → 24.7 ms p50, i.e. **≈ 0.93 ms per MB**. Extrapolating that slope
down to the 2.4 MB calibration image gives **≈ 15.2 ms p50 and ≈ 28.9 ms p100** — both inside the
target, and it is worth being explicit that this is an **extrapolation from two bands, not a third
measurement.**

Consistent with it, `--quick 10` runs against the same locked screen landed **p100 25.6, 27.1 and
29.8 ms** on three consecutive attempts. A 10-sample p100 is a different statistic from a
197-sample one and the larger sample is the honest number: **at ~8 MB the pipeline does not hold
30 ms at p100, and at the size the target was written for it should.**

### What would close the two open rows

Both need an **operator-attended** run, and both are one command:

```
bash scripts/screenshot-bench.sh --quick 30 --min-idle 0
```

With somebody at the machine the screen is unlocked, so (a) the captures are ordinary UI content at
their real sizes, which tests the latency target against the population it was written for, and
(b) `hs.canvas:isOccluded()` can actually go false, so `capture → thumb-visible` becomes measurable
and `winprobe` can falsify it.

Until then the only evidence for the thumbnail path is **two real ⌘⇧4 shots the operator took at
20:43:30 and 20:44:45 while this pipeline was live** (n = 2, and on an earlier build than the one
measured above, so the *copy* numbers in those lines are not comparable — the thumbnail path was
not touched by the later optimisations):

| | `copied` → `thumb-shown` | `thumb-shown` → `thumb-visible` |
|---|---|---|
| 111 KB shot | 6.1 ms | 30.4 ms |
| 487 KB shot | 23.5 ms | 91.3 ms |

That puts capture → fully visible comfortably inside the 200 ms p50 target on the real keyboard
path, on a sample of two.

### The stall proof — Phase 2's Verify criterion, met at 3.02 s

Phase 2 asks for one specific demonstration: deliberately stall `screencapture` between the
complete PNG and the rename, and show `copied` arriving **≥ 2.9 s** before the file gets its final
name. `bench/run.py --stall 3 --stall-every 1`, one capture, 2 391 816 bytes:

| | |
|---|---|
| PNG complete (file mtime) | T |
| `phase=capture-complete` | T + ~11 ms |
| **`phase=copied`** — verified on the clipboard, read from `..Screenshot … .png-Mg6V` | **T + ~22 ms** |
| `phase=thumb-shown` | T + ~35 ms |
| `phase=renamed` → `.Screenshot … .png` (hidden → hidden; ImageIO's own rename) | T + ~394 ms |
| **Apple's FINAL rename** (file ctime − mtime) | **T + 3 032.4 ms** |

So the clipboard held the image, verified byte-for-byte, for **three full seconds** before the file
had the name the old matcher waited for. That is the entire thesis of Phase 2, demonstrated on one
capture, and the whole three-name lifecycle is visible in a single shot's log lines.

**Read it off `ctime − mtime`, not off our own `renamed` line.** The log's first `renamed` is the
*hidden-to-hidden* transition and arrives in milliseconds; the final rename is only noticed when a
listing happens to run, and the bench had already deleted the file by then. The kernel's `ctime` is
the instrument that does not depend on our poll.

**Two earlier `--stall` designs never landed the SIGSTOP** and are written up in `bench/run.py`:
waiting for `.Name.png` watched only one of the two hidden spellings, and globbing for both was
slower than the window is wide (measured: the hidden forms live tens of milliseconds for a 1.6 MB
capture, and both versions produced `renamed − copied` of 0.28–0.74 s, i.e. the ordinary rename
delay and no stall at all). Triggering off the pipeline's own `copied` line costs nothing and
cannot miss.

### 🚨 One thing this session found that is NOT W1's to fix: an 88 s gap after a SIGTRAP

`supervise.sh status` reads `verdict=supervised` with the W1 pipeline live, and its heartbeat check
already accepts this wave's `phase=armed` line — the two waves integrate cleanly. But the job also
reports `runs = 2` and `last terminating signal = Trace/BPT trap: 5`, i.e. **Hammerspoon died once
during this session with SIGTRAP** — the `EXC_BREAKPOINT`-in-`hs.ipc` class that killed the config
on 2026-09-10 at 12:03:36 — and the log shows the gap:

```
ts=2026-09-13T21:00:15.046  phase=error  msg=…/hs/ipc.lua:81: ipc port is no longer valid (early)
ts=2026-09-13T21:01:43.370  phase=start  module=init      ← 88.3 s later
```

**88.3 s with no screenshot detection at all**, against Phase 1's ≤ 2 s downtime target. What is
certain: the crash signature is the hs.ipc one, it was provoked by this session hammering
`hs -c 'hs.reload()'` under bench load rather than by ordinary use, `runs = 2` accounts for exactly
one respawn, and the acceptance run began at 21:15:40, well clear of it. **What is NOT resolved is
why the gap was 88 s when a mature job re-forks in ~1 ms** — that is a supervision question, in
W2's files, which this wave is forbidden to touch. It is recorded here rather than swallowed
because it is the one measured breach of a Phase 1 acceptance row, and because it shows the hs.ipc
crash class is still live: nothing in W1 can stop a Hammerspoon *extension* from printing through a
stale port, so supervision is what covers it.

### What this run did NOT exercise

- **The Apple stall.** 0 of 197 captures stalled ≥ 1 s, against a 30-day user baseline of 2.6 %.
  A clean sheet against a hazard that never occurred is not evidence, which is why `analyze.py`
  prints `INSUFFICIENT-N for the stall class` rather than a pass. The stall is also the one failure
  this whole design removes from the critical path, so the *interesting* run is one that hits it.
- **N ≥ 209.** The run aborted at 197 when the operator returned — the pointer-delta guard working
  as designed, and the reason the requested 300 was not reached.
- **L3**, above.
- **A loss of any kind**: `phase=lost` was never emitted, so the 30 s deadline path is untested.
  The *drop* path is not: a `bench-notpng-probe.txt` placed in `~/Screenshots` produced
  `phase=created` and then `phase=gone reason=not-png` **3.2 ms later**, so the PNG-signature test
  — the thing that makes name-matching unnecessary — works on a real non-screenshot entry.
