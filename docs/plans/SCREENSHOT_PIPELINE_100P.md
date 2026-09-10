---
status: open
title: "⌘⇧4 screenshot pipeline — 100.00 % reliability, 100th-percentile latency"
created: 2026-09-10
owner: hammerspoon-config
---

# ⌘⇧4 screenshot pipeline — 100.00 % reliability, 100th-percentile latency (plan)

**Scope (frozen, 2026-09-10):** bring the ⌘⇧4 drag-screenshot → clipboard (Claude Code ⌘V) →
bottom-right thumbnail pipeline to 100.00 % reliability and 100th-percentile latency and code
quality, on the basis of the measured knowledge base `docs/research/screenshot-pipeline-2026-09-10.md`.
This document is the implementation plan; its waves are executed as dispatched sessions (Phase 0).

**Status:** plan written 2026-09-10 08:45 CDT; K2 verified by two independent refuters at 11:4x
(corrections adopted in Phase 2); the remaining verifications and gap-fill axes died twice on
5-hour session limits and are named in § Verification ledger, not bridged.
Nothing in Phases 1–6 has been implemented yet. Hammerspoon was relaunched by hand at 00:20:18 and
is currently unsupervised.

**Targets (acceptance, all measured by the bench in Phase 5 and by 7 days of real use):**

| metric | today (measured) | target |
|---|---|---|
| screenshots that reach the clipboard with a thumbnail | not 100 % (5.4 h outage; 3 of 9 lost last night; stalls) | **100.00 %** — 0 of N = 300 bench shots lost (L1), clipboard bytes == file bytes N of N (L2), the later of two same-scan shots wins N of N (L3), 0 real shots without a `copied` record over 7 days |
| PNG-complete → clipboard verified | rename-bound: 243 ms p50, 5.0 s p90, 10.2 s max | **≤ 15 ms p50, ≤ 30 ms p100** (10 ms poll + ≤ 1 ms PNG write + verify) |
| capture (mouse-up) → clipboard verified | 243 ms p50 / 10.2 s max | **≤ 70 ms p50, ≤ 250 ms p99** (bounded by Apple's PNG write: 35 ms p50, 162 ms p99) |
| capture → thumbnail fully visible | copied + 250 ms slide | **≤ 200 ms p50** (copied + ≤ 120 ms entrance) |
| detector downtime after a SIGTERM/crash | hours (no supervision) | **≤ 2 s** (launchd respawn 0.05 s + Hammerspoon start) and the shot taken during it is still copied |
| main-thread blocking on the poll path | python3 spawn (54–78 ms idle, seconds under load), TIFF 55 ms, Pop 7 ms, 10 hot rescans/s | **0 synchronous spawns, 0 encodes > 5 ms, 0 listings without a size change; bench R1 max tick gap ≤ 75 ms, R2 zero main-thread blocks > 100 ms** |
| bench sample size | previous verifications used N = 3–10 | **N = 300 default** (a 1.1 % stall needs N ≈ 209 for 90 % odds of one observation); `analyze.py` prints the observed stall count and `INSUFFICIENT-N` when none was seen |

---

## Phase 0 — Agent Team Orchestration

**Execution locus per wave.** S = dispatched session (default, no justification needed); T =
in-session teammates; L = lead-inline.

| wave | locus | why (only T/L need one) | size band (output) | files |
|---|---|---|---|---|
| W1 detection + copy + thumbnail rewrite (Phases 2–4) and the module split (Phase 5a) | **S** | — | 80–150K | `screenshot.lua`, `lib/log.lua`, `init.lua`, `README.md`, `docs/TROUBLESHOOTING.md` |
| W2 supervision (Phase 1) + install/uninstall scripts | **S** | — | 40–80K | `launchd/org.hammerspoon.Hammerspoon.keepalive.plist`, `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/supervise.sh` |
| W3 bench + acceptance harness (Phase 5b) — runs after W1 lands | **S** | — | 40–80K | `scripts/screenshot-bench.sh`, `bench.lua`, `docs/research/…-acceptance.md` |
| W4 retire the fallback agent in claude-infrastructure (Phase 6) — after W2 lands | **S** | — | 20–40K | that repo's `bin/`, `launchd/`, `docs/` |
| W5 experiments (Phase 7: clipboard-destination hybrid, pasteboard watcher, kqueue) | **S**, optional, after W3 numbers | — | 40–80K | scratch + a research doc |

**Roster / roles.** One dispatched session per wave, each with `--goal` naming the measurable end
state and the command that proves it (below). The lead (this session or its successor) reviews
each wave's diff, runs the bench after W1+W3, and merges with `--ff-only`, smallest diff first.

**Dependency graph.** W1 ∥ W2 (disjoint files; W2 must not touch `init.lua`). W3 `blockedBy` W1.
W4 `blockedBy` W2 (the fallback is only retired once supervision is live and proven). W5 `blockedBy` W3.

**Worktrees.** `wt/screenshot-100p-w1` … `-w5` off `origin/main`; `~/.hammerspoon/init.lua` is a
symlink to the main checkout, so a wave tests its own tree by pointing the symlink at its worktree
for the duration of its verification and restoring it (the bench does this and records it).

**Spawn order.** W1 and W2 fired together; W3 when W1 lands; W4 when W2 lands and has survived one
deliberate `launchctl kill TERM`; W5 last.

**Goals (the `--goal` text per wave).**
- W1: *"`bash scripts/screenshot-bench.sh --quick 10` prints `lost 0/10` and `png-complete→copied p100 ≤ 30 ms`, and `tail -n 20 ~/Library/Logs/Hammerspoon/screenshot.log` shows `copied` lines for every bench file; do not touch launchd, the Login Item or the general pasteboard outside the bench's snapshot/restore."*
- W2: *"`bash scripts/supervise.sh --prove` prints `respawn N ms` with N < 2000 after a `launchctl kill TERM`, `pgrep -x Hammerspoon | wc -l` prints 1, and `osascript -e 'tell application "System Events" to get name of every login item'` no longer lists Hammerspoon; do not modify init.lua."*
- W3: *"`bash scripts/screenshot-bench.sh 50` prints `lost 0/50`, `png-complete→copied p100 ≤ 30 ms`, `capture→copied p99 ≤ 250 ms`, `capture→thumb-visible p50 ≤ 200 ms`, and writes `docs/research/screenshot-acceptance-<date>.md`; run only with HIDIdleTime ≥ 60 s and restore the clipboard snapshot."*
- W4: *"`launchctl print gui/$UID/com.chrisren.screenshot-clipboard` exits non-zero, the plist and script are removed from claude-infrastructure through its `/ship` flow, and `docs/TROUBLESHOOTING.md` here no longer names the agent as active."*

**Lead context budget + succession.** The research lead (this session) recycles after this plan
and the knowledge base are committed and landed; the implementation lead is a fresh session that
holds ≥ 50 % of its window for review and merge, and recycles at the W3 boundary (after acceptance
numbers are recorded) if it exceeds 50 % fill.

**Pre-spawn checklist per wave** (agent-teams discipline): brief ≤ 150 lines; every target file
pre-grepped with line ranges; no visual verification inline (the bench measures thumbnail
visibility via CGWindowList, not by eye); "stop on issue, message lead" verbatim; one task per
unit inside the 40–150K band.

---

## Phase 1 — Supervision: Hammerspoon restarts in under a second, exactly one instance (W2)

**Why.** Failure class A: SIGTERMed 2026-09-09 18:55:16 by a fleet census, dead 5.4 h, nothing
relaunched it (KB §F1). The fleet has killed processes by pattern three times before. Measured:
`KeepAlive=true` + `ThrottleInterval=1` respawns in 0.04–0.05 s; the default throttle makes it ~10 s.

**Design.**
1. `launchd/org.hammerspoon.Hammerspoon.keepalive.plist` (user agent, `gui/$UID`):
   `ProgramArguments = [/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon]`,
   `KeepAlive = true`, `RunAtLoad = true`, `ThrottleInterval = 1`, `ProcessType = Interactive`,
   `LimitLoadToSessionType = Aqua`, `AssociatedBundleIdentifiers = org.hammerspoon.Hammerspoon`.
   Install with `launchctl bootstrap gui/$UID <plist>` (never `load`), remove with `bootout`.
2. Remove the Login Item (`osascript -e 'tell application "System Events" to delete login item
   "Hammerspoon"'`) — a `Program`-launched agent bypasses LaunchServices' single-instance check, so
   the Login Item would start a second instance at login (KB §F8 item 3).
3. `defaults write org.hammerspoon.Hammerspoon SUAutomaticallyUpdate -bool false` — Sparkle must not
   quit/relaunch outside launchd; updates stay manual (Hammerspoon menu).
4. Single-instance guard in `init.lua`: at load, if another `Hammerspoon` pid exists (via
   `hs.execute("pgrep -x Hammerspoon")` filtered by `hs.processInfo.processID`), log `second
   instance — exiting` and `os.exit(0)` only when THIS process was NOT launched by launchd
   (`hs.processInfo.… parent pid == 1` identifies the launchd child); the launchd instance always wins.
5. `scripts/supervise.sh {install|uninstall|status|--prove}`: `--prove` records Hammerspoon's pid,
   runs `launchctl kill TERM gui/$UID/org.hammerspoon.Hammerspoon.keepalive`, polls
   `launchctl print` for a new pid, prints `respawn N ms`, then waits for the `poll armed` line in
   `screenshot.log` and prints the total detector downtime. Exit codes carry the verdict.
6. `install.sh`/`uninstall.sh` call `supervise.sh`; `install.sh` stops using `open -a` + quit
   (under KeepAlive a quit is a restart); reload stays `hs -c 'hs.reload()'`.
7. `hs.reload()` and Hammerspoon's own "Reload config" are unaffected (same process).

**Verify.** `supervise.sh --prove` < 2000 ms; `pgrep -x Hammerspoon | wc -l` = 1 after a login
(operator observes once); Accessibility + Screen Recording still work (`hs.eventtap` fires; the
bench's thumbnail appears); TCC unchanged (same signed bundle, KB §F6).

**Rollback.** `supervise.sh uninstall` (bootout + re-add the Login Item via `System Events`).

## Phase 2 — Detection and copy: the dotfile is the file (W1)

**Why.** Failure class A/latency class A: Apple blocks up to 10 s on Spotlight AFTER the PNG is
complete; the matcher waits for the rename (KB §F2). Measured: 10 ms `hs.timer` is stable (p99
11.0 ms); creation always changes the directory's st_size by 32 B; the inode survives the rename;
the PNG-only pasteboard write is 0.5 ms and is exactly what Claude Code reads (KB §F5, §F7).

**Design (`screenshot.lua`, ~350 lines).**
1. **Poll**: `hs.timer.new(0.010, tick, true)` (continueOnError). `tick` does one
   `hs.fs.attributes(dir)`; the signature is `size` alone (plus `mtime`/`ctime` for the
   rename-only case, used below). On a size change → `scan()`. No "hot second" rescans.
2. **Scan**: list the directory; for every name not in `seen` (a table of names) → `seen[name]=true`;
   candidate iff `hs.fs.attributes(path)` is a regular file with `creation ≥ now − 30 s`. **Open the
   file handle immediately and keep it** — Apple renames the same inode twice
   (`..Screenshot X.png-XXXX` streaming temp → `.Screenshot X.png` complete → final name, KB §F2)
   and a handle survives both, so every later check reads through the handle and never through a
   path. Once ≥ 8 bytes exist, the first 8 must be the PNG signature `\137PNG\r\n\26\n`, else the
   candidate is dropped. Name spelling — either hidden form, final, `hs-bench-…`, a Finder copy —
   is irrelevant; the 30 s creation window excludes Finder duplicates of old shots and sync-client
   churn (KB §F8 item 7).
3. **Settle** per candidate, every 10 ms, through the open handle: `size = f:seek("end")`, then
   `f:seek("set", size − 8)` and read 8 bytes until they equal IEND (0.17 ms) — IEND only, no
   size-stability fallback (the streaming temp plateaus between 16 KB chunks and must never be
   copied early). Cap 15 s, then one `W` line, close the handle and release.
4. **Copy**: read the file once through the handle (3 ms for 2.4 MB),
   `hs.pasteboard.writeAllData(nil, {["public.png"]=bytes})`, verify `changeCount` advanced and that
   `readDataForUTI(nil, "public.png")` returns the same byte length (a UTI merely being present is
   not verification — F1 L2), one retry; a monotonic sequence number guards the write so that when
   two shots settle in one scan the later capture ends on the clipboard (F1 L3). No TIFF: the
   pasteboard server serves TIFF readers by translation (KB §F5); `SCREENSHOT_TIFF=true` re-enables
   a second write 60 ms later for the day a consumer proves it needs one.
5. **Dedup by inode, recorded on verified copy** (`copied[ino] = {path, t}`) — never at detection
   (KB §F8 item 1). A candidate whose inode is already in `copied` or already open in a settle is a
   rename: update its current `path`, re-point the thumbnail's click target, done. Because the
   settle reads through the handle, a rename between polls costs nothing; the path is re-resolved by
   inode only when it is needed (thumbnail click, `renamed` log line). A handle whose inode has no
   directory entry left was deleted before completion (log `gone`, close it).
6. **Thumbnail + sound** after the verified copy (Phase 4); Pop is played AFTER the canvas shows.
7. **Arm**: mark all existing names `seen`, but any entry created within the last 15 s that has no
   `copied` record in the log is treated as new (bounded retroactivity — covers the KeepAlive
   restart window, KB §F8 item 4). Never touch anything older.
8. **Directory missing / replaced** (new inode): warn once, keep polling; re-arm on reappearance.
9. **Stranded dotfile** (screencapture killed mid-stall): after 30 s with no rename and no
   `screencapture` process alive, rename `.Screenshot X.png` → `Screenshot X.png` ourselves so the
   Finder archive is complete; log it.
10. **Log** (`lib/log.lua`): one human line per phase with ms wall-clock AND monotonic ns
    (`created`, `complete`, `copied`, `thumb`, `renamed`, `gone`, `warn`), rotated at 1 MB **on
    write**, errors rate-limited to 1/s. The bench parses these lines.

**Verify.** `screenshot-bench.sh --quick 10` (Phase 5): `lost 0/10`, `png-complete→copied p100 ≤ 30 ms`;
a deliberate `kill -STOP` of a CLI `screencapture` between write and rename (bench `--stall` mode
uses `SIGSTOP` on the child for 3 s) shows `copied` before `renamed` by ≥ 2.9 s.

## Phase 3 — Nothing synchronous on the main thread (W1)

**Why.** KB §F4: the python3 Dock rebind (54 ms idle, seconds under load) and the hot rescans
stall the poll and can disable the ⌘V→⌃V tap by timeout.

**Design.** `dock.lua`: `hs.plist.read` (8.6 ms measured) replaces the python spawn; the rebind
runs from a 0.5 s coalescing timer as today; `hs.alert.show` stays but shortened to 0.4 s (cosmetic).
`hs.mouse.getCurrentScreen()` (20 ms measured) is called once per thumbnail, after the copy is
verified, so it is off the clipboard path; if E1's numbers show it dominating the thumbnail
entrance, replace with `hs.mouse.absolutePosition()` + `hs.screen.allScreens()` frame containment.
`hs.sound.getByName("Pop")` (3.9 ms) is loaded once at start and reused. No `hs.execute`,
`os.execute`, `io.popen` or `hs.osascript` anywhere on a timer callback; `hs.task` only.

## Phase 4 — Thumbnail: fastest visible, same guarantees (W1; numbers from E1 when it lands)

**Design.** Keep hs.canvas and every lifecycle fix already learned (`:hide(seconds)` fade,
per-canvas scoped callbacks, GC nudge on dismiss, pointer-display placement). Measured defect to
fix (F1 §5.2): today `THUMB_SLIDE_DUR/THUMB_SLIDE_FPS` yields **3 frames**, the canvas is shown at
x = screen width + 12 (fully off-screen) and the first on-screen pixel appears 83 ms after
`show()` — a third of the visible budget. New entrance: first frame already ~70 % on-screen, then
a 120 ms slide at 60 fps (`hs.timer` at 16 ms measured max 18 ms) — or, if E1 measures the loop as
costlier than ~1 ms/tick, a `:show(0.12)` fade-in with no movement — and `phase=thumb-visible`
logged at the first tick whose on-screen fraction ≥ 0.10. Build the canvas from a pre-scaled 320 px
image. Click opens the current path for the inode (resolved at click time). Dismiss at 3 s as
today. `behaviorAsLabels` adds `fullScreenAuxiliary` if the bench shows the canvas hidden over a
fullscreen Space (unverified; KB §F8 item 10).

## Phase 5 — Structure and proof (W1 for the split, W3 for the bench)

**5a Module split** — adopted from the F1 report (scratchpad `reports/F1-module-structure.v1-08h46.md`,
measured 2026-09-10). Three measured facts decide the shape:
- **The repo is not on `package.path`** (only `~/.hammerspoon` is, built in Hammerspoon's
  `setup.lua`; the config dir is real and only `init.lua` inside it is a symlink). Bootstrap, first
  thing in `init.lua`: `local ROOT = (hs.fs.symlinkAttributes(hs.configdir .. "/init.lua", "target")
  or (hs.configdir .. "/init.lua")):match("(.*)/"); package.path = ROOT .. "/?.lua;" .. ROOT ..
  "/?/init.lua;" .. package.path`. Degrades correctly when `init.lua` is not a symlink.
- **The reload guard at `init.lua:7-20` is dead code**: `hs.reload()` builds a fresh Lua
  environment, so every global it tests is already nil. Replace with the sanctioned surface: a
  module registry plus `hs.shutdownCallback` that calls each module's `stop()` in reverse order,
  each in its own `pcall` (synchronous `:stop()`/`:delete()` only).
- **Globals are unnecessary for GC safety**: a table reachable from `package.loaded` anchors a
  timer exactly as well (measured: 50 ticks vs 0 for an unanchored local). No feature global remains.

Tree: `init.lua` (~45 lines: bootstrap, config, start loop, shutdownCallback) · `hsc/log.lua` ·
`hsc/clock.lua` · `hsc/apps.lua` (the terminal bundle-id table shared by dock + smartpaste — never
duplicated, the defect `2bf64de` fixed) · `hsc/dock.lua` (`hs.plist.read`, 9.2 ms measured, 6.7×
faster than the python spawn) · `hsc/smartpaste.lua` · `hsc/screenshot/{init,watcher,settle,
clipboard,thumbnail}.lua` (watcher and settle pure and testable) · `bench/{run.py, winprobe.swift,
analyze.py}`. Module contract for all: `M.start(cfg)` / `M.stop()` idempotent and safe when never
started, `M.stats()` a plain table for `hs -c` and the harness. **What the split must NOT change**:
the ordering guarantees from commits `664d809`, `e4713ad`, `8e0173a`, `85b003c` (dismiss armed
before the mouse callback, callbacks addressing their own canvas, the slide timer stopping its own
handle, fade via `hs.canvas:hide(s)`) are ported as literal code with their comments.

Three defects the split surfaces (all measured by F1) are fixed in W1: (a) `table.sort(found)` on
names orders same-scan shots wrongly on 67 % of days (non-zero-padded 12-hour hour) — order by
creation time, and guard the clipboard write with a monotonic sequence so two shots in one scan
leave the LATER one on the clipboard; (b) `hs.sound.getByName("Pop")` costs 7 ms inside the settle
path — hoist to module load; (c) the fixed-name TIFF scratch pasteboard is never deleted — with
PNG-only it disappears; any scratch pasteboard uses `uniquePasteboard()` + `deletePasteboard`.
Also: `knownEntries` is add-only forever (a Trash-restored screenshot with a burned name is never
copied and never logged) — `seen` becomes a bounded structure re-synced from the listing, with a
`forget(name)` used by the bench. README and TROUBLESHOOTING updated in the same wave (the
"ask the window server" section should show the prober, not `hs -c`).

**5b Bench** — architecture adopted from F1. One long-lived driver `bench/run.py` (never a spawn
per sample): preflight (Hammerspoon pid, `~/Screenshots` writable, single-item pasteboard — refuse a
multi-item clipboard, `readAllData` only preserves the first item) → presence gate
(`hs.host.idleTime()` ≥ 180 s to start; abort before the next capture on any pointer delta or
idle < 5 s; abort still restores the clipboard and deletes files) → snapshot the general pasteboard
→ N iterations of `screencapture -x -R <rect> ~/Screenshots/"Screenshot BENCH <run-uuid> <seq>.png"`
(unique per run AND per iteration — a deleted name stays burned in the dedup, so reuse would score
every repeat as a loss) with ≥ 2 s spacing → wait for `phase=copied|lost` (deadline 15 s) → verify
`sha1(pasteboard public.png) == sha1(file)` → delete the file only after copied/lost → restore the
clipboard (assert UTI set and byte lengths identical) → `bench/analyze.py`.
**Clock**: `hs.timer.absoluteTime()`, `mach_absolute_time()` and Python's `time.monotonic_ns()` are
the same clock with no offset (measured), and APFS records mtime at µs resolution, so `t0` is the
kernel-recorded mtime of the capture — no poller in the loop. **Thumbnail visibility** is emitted
in-process (`phase=thumb-visible` at the first slide tick whose geometric predicate holds) and
falsified by `bench/winprobe.swift` (`CGWindowListCopyWindowInfo`, one process for the whole run):
Hammerspoon's canvas is the second window at `layer=3`; **`kCGWindowIsOnscreen` means ordered-in,
not on a display** (a canvas at (4000,4000) reports onscreen=true), so visibility is
`area(bounds ∩ screen fullFrame)/area(bounds) ≥ 0.10`. The prober's own scheduling gap reaches
89 ms under this load, so it is the falsifier, never the clock; a disagreement > 100 ms fails the
iteration. Bench mode sets `sound=false` and `dismiss=0.4`; `analyze.py` records the mode and never
compares percentiles across modes. **Log**: `hsc/log.lua` emits one logfmt line per phase —
`id=` 6 hex chars from the inode (so `created`/`complete` can be logged against the hidden name),
`mono=` ns verbatim, `dt=` ns since `created`, bare values with `file=` always last, a closed phase
vocabulary (`created · capture-complete · detected · settling · copied · thumb-shown · thumb-visible
· dismissed · lost · error`), `phase=lost` emitted by a deadline timer so a loss is a positive
record, rotation on write. The old `Ns old` field goes. **Invalidation**: a Hammerspoon pid change
mid-run invalidates the run (its arm pass marks pending files known).
**Honest limits (stated in the harness output)**: `-R` reproduces the keyboard path's file writes
byte-for-byte in sequence (F1, n = 11) but not the interactive phase, so it measures
capture-complete → clipboard, never hotkey → clipboard; its log line reads `launched with
commandline`, which lets the harness identify its own captures; `-R` geometry is points, output is
pixels at display scale; every `-R` contacts `mds`, so 300 captures load the very daemon whose stall
is being measured — report the observed stall rate against the 30-day 1.1 % baseline as a validity
check. The keyboard path itself is proven by 7 days of real use (every real shot has a `copied`
record and the log names its hidden-name lifecycle) and, optionally, by an operator-run synthetic
⌘⇧4 + drag via `hs.eventtap` (`bench/run.py --keyboard`, idle-guarded).

## Phase 6 — Retire the fallback clipboard agent (W4, claude-infrastructure)

**Why.** KB §F1 table: it lost 2–3 of 9 shots by construction (10 s launchd throttle × 10 s recency
guard × Apple's stall), copies PNG only and late, cannot draw the thumbnail, depends on fseventsd,
and inside a KeepAlive restart window it can land an older image over a newer one. With Phase 1
proven, its remaining value is negative.

**Design.** `launchctl bootout gui/$UID/com.chrisren.screenshot-clipboard`; remove
`launchd/com.chrisren.screenshot-clipboard.plist` and `bin/screenshot-to-clipboard.sh` (and the
`~/bin` symlink) through that repo's `/ship` flow; note it in this repo's TROUBLESHOOTING as retired.

## Phase 7 — Experiments (W5, optional; each one closes an open question)

1. **Clipboard-destination hybrid** (devil's advocate, KB §5 B): one operator Ctrl+⌘⇧4 with a 10 ms
   `changeCount` probe armed and the unified log open. If the clipboard path skips the `mds` call,
   document it; the pipeline still keeps file-watch as primary because the archive file must land
   even when Hammerspoon is down.
2. **Pasteboard watcher for Ctrl-held / ⌘⇧5 → clipboard captures**: a foreign `changeCount` bump
   carrying `public.png` with no new file within 300 ms → thumbnail from the pasteboard (KB §F8 item 5).
3. **kqueue/dispatch-vnode helper**: only if C1's numbers show ≥ 5 ms saved at p99 over the 10 ms
   poll; otherwise closed.
4. **Spotlight load on this box** (B1): hand the findings to claude-infrastructure; not this repo's
   fix — the pipeline no longer depends on `mds` after Phase 2.

---

## Decision log (why, so a successor does not re-litigate)

- **File-watch stays the architecture; the dotfile is the file.** The system hotkey is the only
  capture path that survives a dead Hammerspoon and never triggers Sequoia's spawner nag; the PNG
  is complete ~35 ms after the capture and only the rename waits on Spotlight. Copying from the
  temp removes the 10 s class without a new permission, a new binary, or a change to the user's
  archive. (KB §F2, §5; devil's advocate verdict "hybrid at most".)
- **Match by content and creation time, not by name.** The keyboard path's temp spelling is
  observed (`.Screenshot … .png`) but not something the design should depend on; a PNG signature +
  a 30 s creation window is spelling-independent and also blocks Finder-copy hijacks.
- **Inode recorded on verified copy, never at detection** — the one new race the dotfile design
  introduces (hostile review item 1).
- **PNG only.** Claude Code reads `«class PNGf»`; the pasteboard server translates for TIFF
  readers; the TIFF encode was 55 ms of a 60 ms copy. A switch keeps the door open.
- **10 ms poll, no helper.** Measured jitter makes a kernel watcher worth ≤ 10 ms; a compiled
  dependency is not worth that until C1 shows otherwise.
- **KeepAlive with ThrottleInterval=1, Login Item removed, Sparkle auto-update off** — the three
  together are what "exactly one instance, back in under a second" requires.
- **Bounded retroactivity (15 s at arm)** replaces "never retroactive": the 2026-09-08 rationale
  (do not overwrite what the user has since copied) holds for old files, not for a shot taken
  during a 2 s restart.
- **Retire the fallback** rather than fix it: every fix leaves the throttle/age interaction or the
  older-over-newer race in place, and supervision makes its window ~2 s.
- **Hotkey takeover rejected** (dead key when Hammerspoon is dead; spawner nag), **native capture
  rejected** (loses the crosshair/magnifier/window mode), **FSEvents rejected** (2026-09-08).

## Verification ledger (updated as the wave lands)

| claim | verifier verdicts | status |
|---|---|---|
| K1 mds XPC timeout after the PNG is complete | not run (two workflow runs died on session limits) | primary evidence in KB §F2; K2's refuters independently re-derived the mds → mdwrite → rename sequence |
| K2 hidden temp, same inode, bytes final at mtime | **stands** — mechanism 85 %, measurement 88 % (two independent refuters, 0.5 ms hashing pollers, binary call-site analysis, 18 joined keyboard shots) | corrections adopted: three-name lifecycle (`..X.png-XXXX` → `.X.png` → final), the race is a MISS not a wrong image, fd-open remedy in Phase 2 steps 2–5, gain qualified (median 5–10 ms; ≥ 1 s in 4.6 %; 10 s in 1 %) |
| K3 KeepAlive/ThrottleInterval/TCC/double-launch | not run (session limits; re-run is the operator's quota call) | measured KB §F6 |
| K4 st_size invariant, 10 ms timer, inode dedup at verified copy | not run (session limits; re-run is the operator's quota call) | measured KB §F7, §F3 |
| K5 PNG-only pasteboard suffices for Claude Code | not run (session limits; re-run is the operator's quota call) | binary evidence KB §F5 |
| K6 SIGTERM by the census bug; nothing restarts Hammerspoon | not run (session limits; re-run is the operator's quota call) | launchd log KB §F1 |
| gap-fill B1 / C1 / E1 / F1 | not run (session limits + capacity gate) | each has a lead-designed fallback in Phase 7.4 / 7.3 / Phase 4 / Phase 5; the bench closes E1 and C1 by measurement after landing |

## Risks and rollbacks

| risk | mitigation / rollback |
|---|---|
| launchd-spawned Hammerspoon loses a TCC grant | grants are keyed to the signed bundle (measured holdings in KB §F6); `supervise.sh uninstall` restores the Login Item in one command |
| a second instance appears (Sparkle, Login Item re-added by an installer) | single-instance guard logs and exits the non-launchd instance |
| a dotfile that is not a screenshot lands in `~/Screenshots` | PNG signature + 30 s creation window; anything else is logged and ignored |
| the 10 ms poll costs CPU under extreme load | 0.6 % of a core measured; the timer interval is one constant |
| a consumer needs TIFF | `SCREENSHOT_TIFF=true` re-enables a delayed second write |
| the bench perturbs the operator | idle guard, pointer-movement abort, clipboard snapshot/restore, self-cleaning files |

## Open questions (owner, closing action)

1. Keyboard-path temp spelling — W1 (log the first real shot's names after landing).
2. Clipboard destination skips `mds`? — W5 experiment 1 (operator presses Ctrl+⌘⇧4 once).
3. `fullScreenAuxiliary` over fullscreen Spaces — W3 bench.
4. What loads `mds` — B1 (pending), then claude-infrastructure.
