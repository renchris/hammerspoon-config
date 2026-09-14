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
Gap-fill reports B1, D2, E1 and F1 (with its addendum) are integrated below (2026-09-10 15:3x).
Hammerspoon was relaunched by hand at 00:20:18, displaced by a stray second instance at 12:03:36
(KB §F1b; two shots lost outright at 13:33), and relaunched again at 15:16:28 — still unsupervised.
**2026-09-13 (W2+W4, one dispatched session): Phase 1 IMPLEMENTED and proven live** — Hammerspoon
runs under `org.hammerspoon.Hammerspoon.keepalive`; `supervise.sh --prove`: respawn 49 ms, detector
downtime 565 ms, 1 instance; Login Item removed only after TCC was asserted on the launchd instance.
**Phase 6 DONE the same session**: the fallback agent is retired in claude-infrastructure
(`f0e75272b`, landed) and booted out on this box — details and the one resurrection path under its
heading.

**🚀 W1 + W3 LANDED 2026-09-13 (Phases 2, 3, 4, 5a, 5b).** `init.lua` is a loader; every feature is
a module under `hsc/`; `bench/` and `scripts/screenshot-bench.sh` exist and run. Per-phase status
lines are inline below, and § W1 acceptance record carries what the wave measured — including three
findings that correct this document. W2 landed Phase 1 and Phase 6 in parallel (`88b99e9`,
`9221631`, `6573e94`, `aa76097`, `4f44865`, `536aa35`, `26049e1` on `main`), so **failure class A is
closed too**: `gui/501/org.hammerspoon.Hammerspoon.keepalive` is loaded, exactly one instance is
running, and the W1 acceptance run below was measured under that supervision.

**Targets (acceptance, all measured by the bench in Phase 5 and by 7 days of real use):**

| metric | today (measured) | target |
|---|---|---|
| screenshots that reach the clipboard with a thumbnail | not 100 % (5.4 h outage; 3 of 9 lost last night; stalls) | **100.00 %** — 0 of N = 300 bench shots lost (L1), clipboard bytes == file bytes N of N (L2), the later of two same-scan shots wins N of N (L3), 0 real shots without a `copied` record over 7 days |
| PNG-complete → clipboard verified | rename-bound: 243 ms p50, 5.0 s p90, 10.2 s max | **≤ 15 ms p50, ≤ 30 ms p100** (10 ms poll + ≤ 1 ms PNG write + verify) |
| capture (mouse-up) → clipboard verified | 243 ms p50 / 10.2 s max | **≤ 70 ms p50, ≤ 250 ms p99** (bounded by Apple's PNG write: 35 ms p50, 162 ms p99) |
| capture → thumbnail fully visible | copied + 250 ms slide | **≤ 200 ms p50** (copied + ≤ 120 ms entrance) |
| detector downtime after a SIGTERM/crash | hours (no supervision) | **≤ 2 s** (launchd re-fork ~1 ms + Hammerspoon start ~0.6–2 s) and the shot taken during it is still copied |
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

**Status: DONE 2026-09-13 (W2)** — commits `feat: launchd KeepAlive supervision of Hammerspoon —
respawn 49 ms, exactly one instance`, `fix: supervise.sh needs no coreutils timeout…`, `feat: install
and uninstall hand Hammerspoon to launchd supervision`, `docs: troubleshooting for launchd
supervision…`. Measured live: install armed the watcher 498 ms after bootstrap; **TCC
`accessibility,screen-recording,eventtap = true,true,true` on the launchd-started instance**, asserted
BEFORE the Login Item was deleted, with auto-rollback to the old launcher on any `false` (this closes
§ Completeness critic item 1 mechanically — the untested launch provenance is now tested on every
install); `--prove` respawn **49 ms**, detector downtime **565 ms** (kill → `poll armed`), 1 instance;
`uninstall` → `install` round trip restored and re-removed the Login Item (hidden flag and Sparkle
value recorded once, restored exactly); `install` is idempotent. Learnings: (1) bootstrapping with
`RunAtLoad` beside a LaunchServices instance IS the §F1b double launch, so `install` SIGTERMs the
unsupervised instance first; (2) `status`/`--prove` read both the legacy `poll armed` line and W1's
logfmt `phase=armed`, so W1's log rewrite does not break supervision; (3) the plist's
ProgramArguments stays the binary, never a `supervise.sh --run` wrapper — a wrapper would make
Hammerspoon's launch depend on a git checkout existing and change the TCC provenance just verified.
Step 4 (single-instance detection via `pcall(require, "hs.ipc")`) lives in `init.lua` and is W1's.

**First real crash, recovered unattended (2026-09-13 21:01:43).** The launchd instance (pid 27658,
running W1's config through the symlink during its bench) died of **`EXC_BREAKPOINT` in
`CFMessagePortSendRequest` ← `libipc ipc_sendMessage`** (`~/Library/Logs/DiagnosticReports/
Hammerspoon-2026-09-13-210146.ips`) — the **same hs.ipc crash class as 2026-09-10 12:03:36**, preceded
88 s earlier by `phase=error msg=…hs/ipc.lua:81: ipc port is no longer valid (early)`: something
still sends to a dead `hs -c` client's port. KeepAlive re-forked it and the watcher logged
`phase=armed` at 21:01:43.794 — **~0.7 s crash → armed, no human involved**; `status` showed
`launchd_runs=2`, `launchd_last_terminating_signal=Trace/BPT trap: 5`. Before this phase the same
crash meant hours dead. 🚨 **Owner W1**: the crash class is still live under the new config; a
shipped `hs -c`-heavy bench will keep triggering it.

**Why.** Failure class A: SIGTERMed 2026-09-09 18:55:16 by a fleet census, dead 5.4 h, nothing
relaunched it (KB §F1). The fleet has killed processes by pattern three times before. Measured:
`KeepAlive=true` + `ThrottleInterval=1` respawns in 0.04–0.05 s; the default throttle makes it ~10 s.
Second incident the same day (KB §F1b): a hand-launched second instance displaced the live one at
12:03:36, its config aborted at `hs.ipc.cliInstall()`, and the fallback agent deferred to the
zombie — so supervision must key on a heartbeat, and the config must survive a taken IPC port.

**Design.**
1. `launchd/org.hammerspoon.Hammerspoon.keepalive.plist` (user agent, `gui/$UID`):
   `ProgramArguments = [/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon]`,
   `KeepAlive = true`, `RunAtLoad = true`, default `ThrottleInterval` (K3 refuters: a mature job
   respawns in ~1 ms regardless; `=1` would only turn a start-up crash into a 1 Hz loop), `ProcessType = Interactive`,
   `LimitLoadToSessionType = Aqua`, `AssociatedBundleIdentifiers = org.hammerspoon.Hammerspoon`.
   Install with `launchctl bootstrap gui/$UID <plist>` (never `load`), remove with `bootout`.
2. Remove the Login Item (`osascript -e 'tell application "System Events" to delete login item
   "Hammerspoon"'`) — a `Program`-launched agent bypasses LaunchServices' single-instance check, so
   the Login Item would start a second instance at login (KB §F8 item 3).
3. `defaults write org.hammerspoon.Hammerspoon SUAutomaticallyUpdate -bool false` — Sparkle must not
   quit/relaunch outside launchd; updates stay manual (Hammerspoon menu).
4. Single-instance detection without a spawn (F1 report §15c — `hs.processInfo` has no parent-pid
   field and a `pgrep` spawn at load is what Phase 3 removes): `local ipcOK = pcall(require, "hs.ipc")`
   AFTER the modules have started; a failure means another instance owns the `Hammerspoon` port —
   log it, keep the screenshot pipeline running (it does not need IPC), and surface it in `stats()`.
   `hs.ipc.cliInstall()` is dropped: both `hs` symlinks already exist and are Homebrew's. The
   launchd job stays the only launcher; a launchd instance never exits on this signal (KeepAlive
   would respawn it into the same condition), it only reports.
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

**STATUS: LANDED 2026-09-13** (`8cb973b`, `cbe893e`, `b68bf27`). Every step of the design below
shipped as written except where § W1 acceptance record names a correction. Measured live at arm:
`entries=3425 expect=3425 invariant=holds` — the corrected `size/32` predicate (step 2b(a)) is
right on this volume, and the code prints both numbers exactly as this phase demanded. Idle
listing rate is **1.00 per second** and nothing else, i.e. the backstop alone; **3.9–4.3 listings
per shot** under bench load, inside the budget the decision log sets.

**Why.** Failure class A/latency class A: Apple blocks on Spotlight AFTER the PNG is complete —
**unboundedly, not for 10 s** (K1 refuters: 13.7 s and 29.4 s observed) — and the matcher waits for
the rename (KB §F2). Measured: 10 ms `hs.timer` is stable (p99 11.0 ms); creation always changes the
directory's st_size by 32 B; the inode survives the rename; the PNG-only pasteboard write is 0.5 ms
and is exactly what Claude Code reads (KB §F5, §F7).

**B2 (disassembly, 2026-09-11) settles that this phase's approach is the ONLY one.** The stall is an
unguarded straight-line call — `sub_100019794` at `0x1000192b4`, doing `MDItemCreate` →
`MDItemSetAttributes` — sitting between `CGImageDestinationFinalize` (the PNG is complete) and the
`moveItem` to the final name. **No preference, no directory exclusion and no flag reachable from
outside the process removes it**; there is no branch to take. Three further constraints this phase
must honour, all static:

- 🚨 **Never treat a `screencapture` exit code as a capture verdict.** Escape cancels with **exit 0**
  (keycode `0x35` → `mov w0,#0; bl _exit`), and ⌘-period does the same; an asleep display is exit 1
  with nothing written. Any `hs.task` harness needs a display-awake precondition and an
  artifact-based success test. The folklore "returns 1 on cancel" is wrong.
- **`screencapture` does not exit until after the rename**, so anything that shells out and waits on
  the process inherits the whole stall — only a directory watcher escapes it.
- **`show-thumbnail` is `0` today and that is a precondition, not a constant.** Turning it on adds a
  second, *user-paced* move owned by `screencaptureui`, and the inode/dotfile logic must be
  re-validated against it. Free bonus available on the finished file: `kMDItemScreenCaptureType` as a
  provenance field, if the log or thumbnail ever wants to distinguish ⌘⇧3/⌘⇧4/window shots.

**Sequencing constraint from F2:** the settle loop's repeated full-PNG read is **latent today**
(`screencapture` renames a complete file, so `settleStep` finds IEND on its first look — measured
`settled` p50 29.5 ms, max 101 ms, n=30, zero give-ups) and **becomes live the moment this phase
lands**. The tail-8-byte IEND check must therefore ship *with* step 3, not as a later optimisation.

**And there is a live defect this phase closes, independent of the stall (C1, KB §F7, failure mode
14).** The shipped poll keys on `mtime:ctime:size` at whole-second granularity, so a final rename
landing in the last ~30 ms of a wall-clock second changes *nothing* it looks at, and `HOT_EVERY`
covers only the remainder of that second — detection is then deferred until the next screenshot,
which is unbounded. Measured exposure at the shipped 50 ms poll: **11/20 offsets deferred or lost in
a phase-locked sweep, ~3 % of shots**, with one production instance already on disk (**6 026 ms**,
its ctime fractional second 0.987). If this phase slips, land step 1's signature change on its own
first — it is one line and it closes the defect.

**Design (`screenshot.lua`, ~350 lines).**
1. **Poll**: `hs.timer.new(0.010, tick, true)` (continueOnError). `tick` does one
   `hs.fs.attributes(dir)`; the signature is **`size` alone — no `mtime`/`ctime` term at all**. On a
   size change → `scan()`. No "hot second" rescans. **(C1, adopted: a size-only signature
   deliberately ignores renames, which is correct precisely because this design no longer depends on
   them — it triggers on creation, and a creation always moves st_size. Adding mtime/ctime back is
   what re-opens failure mode 14, because at whole-second granularity they are identical across a
   same-second rename. Measured with size-only: first-name detection p50 4.705 / p90 10.011 /
   p99 11.050 ms, 35/35 caught; and the poll's main-thread cost falls from 23.35 directory listings
   per shot to 1.00 — a bigger win than the rejected kqueue helper's 4 ms, at zero cost.)**
1b. 🚨 **BACKSTOP — a 1 Hz unconditional rescan (critic item 5; this is NOT optional).** A size-only
   signature is blind to a **net-zero tick**: K4/mechanism measured `create A + unlink B in one
   interval → Δsize 0` (n=20). Since step 2b only runs "after a size change", such a tick would lose
   the shot **with no later trigger at all** — the same unbounded-deferral shape as failure mode 14,
   which this signature was chosen to close. This is not hypothetical: **Phase 5b's own bench deletes
   each file after `copied`/`lost` in the same directory as the next capture 2 s later**, and the
   directory demonstrably receives non-screenshot traffic (`IMG_4594.jpg`, a `.mov` from ⌘⇧5).
   Cost of the backstop: one listing per second = **2.4 ms, ~0.24 % of a core**, invisible beside the
   10 ms poll. Additionally, **the bench must unlink into a different directory** so it stops
   manufacturing the failure it is grading.
2. **Scan**: list the directory; for every name not in `seen` (a table of names) → `seen[name]=true`;
   candidate iff `hs.fs.attributes(path)` is a regular file with `creation ≥ now − 30 s`. **Open the
   file handle immediately and keep it** — Apple renames the same inode twice
   (`..Screenshot X.png-XXXX` streaming temp → `.Screenshot X.png` complete → final name, KB §F2)
   and a handle survives both, so every later check reads through the handle and never through a
   path. Once ≥ 8 bytes exist, the first 8 must be the PNG signature `\137PNG\r\n\26\n`, else the
   candidate is dropped. Name spelling — either hidden form, final, `hs-bench-…`, a Finder copy —
   is irrelevant; the 30 s creation window excludes Finder duplicates of old shots and sync-client
   churn (KB §F8 item 7).
2b. **Reconcile** (K4 refuters) — 🚨 **PREDICATE CORRECTED; the original was wrong three ways
   (critic item 4, measured on disk).** A size change means the entry COUNT changed, and a listing
   races Apple's renames (an entry mid-rename is missed ~20 % of listings), so after every size
   change re-list every tick until the count reconciles, bounded at 10 ticks, opening each
   not-yet-seen name and holding its handle; ENOENT on open means the name moved under us — the next
   listing finds the same inode under its new name. **What changed, and why the original could never
   have terminated:**
   - **(a) Off by two under the API this plan actually uses.** `size/32 − 2` is right for POSIX
     `listdir`, but `hs.fs.dir` **yields `.` and `..`**. Measured on the live directory: the shipped
     arm line prints `3383 entries known` (screenshot.log 2026-09-10 16:02:48) against
     `st_size 108256 / 32 = 3383`, while python `len(os.listdir())` = 3381. **Under `hs.fs.dir` the
     predicate `== size/32 − 2` never holds, so the bounded loop would burn all 10 ticks on every
     single shot.** The correct predicate is a **name-set count against `size/32`**.
   - **(b) Wrong key.** The predicate counted *inodes*, but `hs.fs.dir` returns **names only** — only
     `hs.fs.attributes` exposes `ino`, so an inode set means statting every entry: **18.0 ms per full
     pass** (n=5: 17.3/18.0/18.3/18.4/21.3) versus **2.4 ms** for the listing alone. Up to ~180 ms of
     main thread per shot — against Phase 3's own acceptance of "zero main-thread blocks > 100 ms".
     **Stat only the names absent from `seen`.**
   - **(c) Names and inodes are not 1:1** — each shot's inode wears three names in succession, so a
     naive name-count reconcile drifts permanently upward while `st_size` does not move. The count
     compared must be the directory's *current* name set, re-read each tick, never an accumulator.
   - **Print both numbers at arm** (`entries known` and `size/32`) so the constant is measured on the
     real volume rather than assumed.
3. **Settle** per candidate, every 10 ms, through the open handle: `size = f:seek("end")`, then
   `f:seek("set", size − 8)` and read 8 bytes until they equal IEND (0.17 ms) — IEND only, no
   size-stability fallback (the streaming temp plateaus between 16 KB chunks and must never be
   copied early). Cap 30 s (K1: the stall is unbounded — 13.7 s and 29.4 s observed), then one `W` line, close the handle and release.
4. **Copy — before any decode**: read the file once through the handle (3 ms for 2.4 MB),
   `hs.pasteboard.writeAllData(nil, {["public.png"]=bytes})` with NO explicit `clearContents` (the
   wrapper clears; the explicit call is a second changeCount bump that wakes pollers on an empty
   board — D2), verify `changeCount` advanced and that
   `readDataForUTI(nil, "public.png")` returns the same byte length (a UTI merely being present is
   not verification — F1 L2), one retry; a monotonic sequence number guards the write so that when
   two shots settle in one scan the later capture ends on the clipboard (F1 L3). No TIFF: the
   pasteboard server serves TIFF readers by translation (KB §F5); `SCREENSHOT_TIFF=true` re-enables
   a second write 60 ms later for the day a consumer proves it needs one.
   Only after the verified write does the pipeline touch `hs.image` (the thumbnail's decode is
   ~47 ms for a 2.4 MB capture at 2×; E1 report §5) — the clipboard is usable ~50 ms earlier on big
   captures than today's TIFF-first order.
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

**STATUS: LANDED 2026-09-13** (`f17a8af`, `b68bf27`). `hs.plist.read` replaces the python spawn;
no `hs.execute`/`os.execute`/`io.popen`/`hs.osascript` survives anywhere (the two remaining
out-of-process calls — the `screencapture` liveness test for a stranded dotfile and the
`com.apple.screencapture` defaults read — are `hs.task`, asynchronous, off every latency path).
The lazy-module warm at load shipped **and grew a fourth member the bench found**: `hs.pasteboard`
was still being loaded on first ACCESS inside the copy path, and across three consecutive runs the
first capture was the slowest every time (30.9 / 31.0 ms against a 26.1 ms worst case for the
other nine). See § W1 acceptance record.

**Why — RESTATED after F2's full audit (2026-09-11, live Hammerspoon at load 33–39); the original
rationale was right in direction and wrong in magnitude.** The Dock rebind is **not** what blocks
this pipeline: `com.apple.dock.plist` was written **twice in 24 h**, so `rebind()` runs ≈2×/day, and
the poll tick is **6 µs**, the eventtap callback 15 µs. **Fix it for its TAIL, not its mean**:
`hs.execute` is `io.popen` + `read('*a')` + `close()` — a synchronous fork/exec/waitpid **with no
timeout at all**, median 43 ms and **worst case unbounded** (a hung `/usr/bin/python3` hangs the main
thread forever, and the Xcode-CLT shim can block on a GUI dialog). That unbounded wait, not the
54 ms, is the reason to remove it.

**What actually costs main-thread milliseconds is elsewhere, and Phases 2/4 own it**: ~120 ms per
*shot* (TIFF materialisation `init.lua:440-442` at 52 ms + the thumbnail's first render at 69 ms) —
40× the rebind's entire daily total, every shot.

**Also corrected (KB §F4 table): these were first-call artifacts, not per-shot costs.** The 20 ms
`getCurrentScreen` is **8 µs** median, the 3.9 ms `getByName("Pop")` is **4 µs**, `hs.plist.read` is
**1.88–2.02 ms** not 8.6, the 7 ms listing is **1.97 ms** median. And **the ⌘V→⌃V tap self-heals** —
`libeventtap.m` re-enables on both `kCGEventTapDisabledByTimeout` and `…ByUserInput` — so a stall
drops events during it but does not leave the tap dead. Hostile review item 6 is half wrong.

**Design.** `dock.lua`: `hs.plist.read` replaces the python spawn — for the unbounded-wait removal;
the rebind runs from a 0.5 s coalescing timer as today; `hs.alert.show` stays but shortened to 0.4 s
(cosmetic). `hs.mouse.getCurrentScreen()` is called once per thumbnail after the copy is verified,
so it is off the clipboard path; E1's replacement (`hs.mouse.absolutePosition()` +
`hs.screen.allScreens()` frame containment) stays — it is genuinely cheaper and cleaner — but its
saving is ~8 µs/shot, not 20 ms, so it is not a latency lever. `hs.sound.getByName("Pop")` is loaded
once at start and reused (saves 4 µs, kept for tidiness). No `hs.execute`, `os.execute`, `io.popen`
or `hs.osascript` anywhere on a timer callback; `hs.task` only.

**New in this phase — warm the lazy modules at load (F2 §9; nobody had proposed it).** `hs.mouse`,
`hs.screen`, `hs.sound` and `hs.canvas` are first touched inside `settleStep`/`showThumbnail`, so
**the first screenshot after every Hammerspoon launch pays ~20–40 ms of module loading on the user's
latency path** — and this box relaunches often (3 `poll armed` lines on 2026-09-10, two 46 minutes
apart). One line at load moves it off the first shot:
`hs.mouse.absolutePosition(); hs.sound.getByName("Pop"); hs.canvas.new({x=0,y=0,w=1,h=1}):delete()`.

**And a stall is never made up.** A 351 ms block across a 50 ms repeating timer produced **seven
missed fires collapsed into one** — CFRunLoopTimer coalesces and does not catch up. Detection latency
for a shot inside a stall of duration *D* is therefore `D + one scan`. Nothing is lost (the catch-up
tick's `hs.fs.dir` sees the new name), which vindicates the 2026-09-08 name-dedup choice; it is purely
latency. This is why the bench's stall test must assert on latency, not on loss.

## Phase 4 — Thumbnail: fastest visible, same guarantees (W1; numbers from E1 when it lands)

**STATUS: LANDED 2026-09-13** (`8cb973b`, `cbe893e`). The slide is deleted, the canvas is built at
its final position and entered with `hs.canvas:show(0.12)`, `phase=thumb-visible` comes from
`isOccluded()`, screen frames are cached behind `hs.screen.watcher`, and every lifecycle fix from
`664d809` / `e4713ad` / `8e0173a` / `85b003c` is ported as literal code with its comments (the
"timer stops its own handle" lesson moved to the visibility probe, which is the only timer left).
Measured on real keyboard shots: `thumb-shown` 6–24 ms after `copied`, `thumb-visible` 30–91 ms
after that. **E1 §7's click-path rule was incomplete and is corrected** — see § W1 acceptance
record — and **thumbnail visibility cannot be measured by an unattended bench at all**, because
the 180 s idle gate guarantees a locked screen.

**Design.** Keep hs.canvas and every lifecycle fix already learned (`:hide(seconds)` fade,
per-canvas scoped callbacks, GC nudge on dismiss, pointer-display placement). Measured defect to
fix (F1 §5.2): today `THUMB_SLIDE_DUR/THUMB_SLIDE_FPS` yields **3 frames**, the canvas is shown at
x = screen width + 12 (fully off-screen) and the first on-screen pixel appears 83 ms after
`show()` — a third of the visible budget. E1 measured the answer: **delete the slide.** Build the canvas at its final position and make
the whole entrance `hs.canvas:show(0.12)` — a Core Animation fade on the window server, 0.02–0.05 ms
of main thread, no timer, no globals, and it removes the state the `664d809`/`e4713ad` bugs lived in.
`phase=thumb-visible` is emitted from `hs.canvas:isOccluded()` (F1 addendum §16: the oracle;
`isShowing()` is not one). Pointer display from a cached screen-frame table refreshed by
`hs.screen.watcher` (the 20 ms was the Lua wrapper, E1 §6). Do not pre-scale the image and do not
set `wantsLayer` — both refuted by measurement. Click resolves the path by stripping the leading
dot(s) and one inode check, never by scanning the directory (E1 §7). Click opens the current path for the inode (resolved at click time). Dismiss at 3 s as
today. `behaviorAsLabels` adds `fullScreenAuxiliary` if the bench shows the canvas hidden over a
fullscreen Space (unverified; KB §F8 item 10).

## Phase 5 — Structure and proof (W1 for the split, W3 for the bench)

**STATUS: 5a and 5b LANDED 2026-09-13** (`e404ef5`, `f17a8af`, `d3028cd`, `2b87cc2`). The tree is
as specified below with two deliberate departures, both noted in § W1 acceptance record: there is
no `hsc/clock.lua` consumer outside `hsc/log.lua` (it exists, small, to keep the monotonic and wall
clocks from being confused), and `bench/winprobe.swift` owns the pointer, the HID idle clock, the
display/lock state and the pasteboard as well as the window list, because this box has no pyobjc
and the alternative was a second native helper.

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
started, `M.stats()` a plain table for `hs -c` and the harness. **Every `require` and every
`start()` runs under its own `pcall`, screenshot module first** (F1 addendum §15b — the 12:03
incident proved one unguarded line takes everything down); no bare `print` (hs.ipc replaces it
with a version that raises on a stale port — write through `hsc/log.lua`). `hsc/log.lua` keeps its
file handle open (today's per-line open/close is measurable) and stamps `created` with the poll's
own `absoluteTime()` at first sight, because `hs.fs` truncates every file timestamp to whole seconds
(F1 addendum §17). **What the split must NOT change**:
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
record, rotation on write. The old `Ns old` field goes. **Invalidation**: a new `poll armed` line
mid-run invalidates the run — a reload keeps the pid (F1 addendum §19), so the pid is not the signal.
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

**Status: DONE 2026-09-13 (W4, same session as W2, after `--prove` passed).** claude-infrastructure
`f0e75272b` (`chore(launchd): retire com.chrisren.screenshot-clipboard…`) + `02b1b2ae6` (bats
SC2066 fix the land gate caught) landed via `ship-land.sh`, content-verified, sweep clean. That
change also dropped the tool from `install.sh`'s and `sync.sh`'s `~/bin` lists (sync copies `~/bin`
BACK into the repo, so a stale copy would have resurrected it), flipped its `fleet.manifest` row to
`retired` rather than deleting it, and updated `osa-bounds.bats`, the unattended-path allowlist and
the README job table. Live box: agent booted out (`launchctl print` → 113, "Could not find
service"), `~/Library/LaunchAgents/…screenshot-clipboard.plist` and `~/bin/screenshot-to-clipboard.sh`
(a real file, not a symlink) removed. Two things for a successor:
- 🚨 **It can be resurrected by infra's deployer.** At retirement time `postland-verify` was running
  on `b359dcfdc` — the tree just BEFORE the retirement. If that stamps green, `deploy-live` advances to
  it, and its `install.sh` re-copies the plist + script and re-bootstraps the `run`-declared label
  (it even clears a disabled bit first, so `launchctl disable` cannot pre-empt it); the newer
  `install.sh` never boots a retired label out again. **Detection shipped here instead of a change
  to infra's autonomous deploy path:** `supervise.sh status` prints `fallback_agent=LOADED` + the
  removal one-liner and turns NOT-HEALTHY.
- **Gate chosen: `--prove`, not critic item 2's 7 days** (the dispatch brief's call). The residual
  critic 2 names is real and now unowned by any running thing: a start-up crash loop relaunches every
  10 s with no notification. `status` makes it legible (`launchd_runs` climbing with a young `age_s`,
  `launchd_last_exit_code`), but nothing runs `status` on a schedule — that is critic item 6's
  auditor (heartbeat file + birth-time join), still open. What was lost is small: the fallback
  deferred on any Hammerspoon pid, so it covered a crash loop only in the gaps between relaunches,
  late and PNG-only.

## Phase 7 — Experiments (W5, optional; each one closes an open question)

1. **Clipboard-destination hybrid** (devil's advocate, KB §5 B) — **the experiment's QUESTION is now
   answered statically by B2; only its product decision remains.** `-c` **structurally cannot stall
   on Spotlight**: every `MDItem*` call site in the binary sits inside the file-writing function or
   its helper, and the clipboard function (`0x100019954`) contains none and reaches none. It also
   writes **exactly one flavor** — a single `PasteboardPutItemFlavor` call site, not in a loop, on
   `PasteboardCreate("com.apple.pasteboard.clipboard")` — which upgrades D2 §7 from reasoned to
   static fact and confirms **PNG-only is what Apple's own Control-held capture does**. So no
   measurement run is needed to decide whether the stall is skipped; it is. What remains is purely a
   product call: the pipeline still keeps file-watch as primary because **the archive file must land
   even when Hammerspoon is down**, and the clipboard destination changes the user's archive
   semantics. Cost of running it anyway: one capture, for the changeCount timing only.
2. **Pasteboard watcher for Ctrl-held / ⌘⇧5 → clipboard captures**: a foreign `changeCount` bump
   carrying `public.png` with no new file within 300 ms → thumbnail from the pasteboard (KB §F8 item 5).
3. ~~**kqueue/dispatch-vnode helper**~~ — **CLOSED by C1 (delivered), do not re-open speculatively.**
   The bar was ≥ 5 ms saved at p99; measured saving is **~4 ms at p50 and ~7 ms at p99** (helper
   p50 0.503 / p99 4.224 ms vs the size-only 10 ms poll's p50 4.705 / p99 11.050 ms, n=35 each,
   through the real `hs.task` streaming path). Rejected: that 4 ms sits on a path already carrying
   Apple's 16 ms PNG write and a 250 ms slide-in, and it is bought with a blind spot the poll does
   not have (**directory replacement ⇒ the watcher goes permanently deaf**, C1 FM2), a second
   unsupervised process on a box where the first one died twice in one day, and a compiled artifact
   to keep building. **Re-open only if** the final-name rename becomes load-bearing again — then
   `NOTE_RENAME` + `F_GETPATH` on a held fd is genuinely better than anything a poll can do, the
   prototype is at `…/scratchpad/c1-work/bin/kqwatch` with the `hs.task` integration in C1 §9, and
   C1's FM2/FM3 (re-open on directory replacement) are mandatory before it ships.
4. **Spotlight load on this box** (B1, delivered): `mds` is not chronically busy; the timeouts
   cluster after rapid CLI capture bursts (partly our own probes), and 3.06 M of the index's 15.6 M
   documents are abandoned projects' `node_modules` under `~/Development`. Operator-side lever:
   Spotlight Privacy exclusion of those directories (or a `.noindex` rename), filed as an operator
   step, not this repo's fix — the pipeline no longer depends on `mds` after Phase 2.

---

## W1 acceptance record (2026-09-13) — what the wave measured, and what it corrects here

Commits: `e404ef5` log/clock · `8cb973b` hsc/screenshot · `f17a8af` dock/apps/smartpaste ·
`d3028cd` the loader · `cbe893e` path resolution across both renames · `2b87cc2` the bench ·
`b68bf27` the performance work.

### Two pre-landing gates closed, one of them by accident of instrumentation

**Completeness critic item 3 is CLOSED, and Open question 1 with it.** The keyboard path's
hidden-name lifecycle had never been observed live; the critic's warning was that W1 could
otherwise "ship a detector that silently drops every real shot while the CLI bench prints
`lost 0/300`". It did not need a `kqwatch` arm in the end: at **20:43:30** and **20:44:45** on
2026-09-13 the operator took two ordinary ⌘⇧4 shots while the new pipeline was live, and the log
caught one under **`.Screenshot 2026-09-13 at 8.43.29 PM.png`** (the complete second name, copied
3.3 ms after first sight) and the other under
**`..Screenshot 2026-09-13 at 8.44.44 PM.png-NKr8`** (the streaming temp, copied 40.7 ms after
first sight, 27.0 ms after the PNG was complete) — both hidden forms, in the spelling KB §F2
predicts, with `phase=renamed` arriving 0.3–0.5 s later in both cases. **Zero CLI captures were
spent establishing this.** The premise is no longer validated only by the artifact built on it.

**Critic items 7 and 9 are implemented.** `show-thumbnail` and `target` are read at module start
through `hs.task` and WARNed on if they are anything but `0`/`file`; the clipboard's `changeCount`
is re-checked 300 ms after every verified write and logs `phase=clobbered` when somebody else moved
it. The clobber detector fired on its first bench run — on the bench's own clipboard *restore*,
which is a true positive and exactly the class the check exists for.

### Three findings that correct this document

**1. E1 §7's click-path rule resolves only ONE of the two renames.** "Strip the leading dot(s) and
make one inode check" handles `.Name.png → Name.png`, but the streaming temp is
`..Name.png-XXXX` — dots *and* an mkstemp suffix — so a candidate caught under it resolved to
nothing. Found by the very first bench capture, which copied correctly and then logged
`no thumbnail (image could not be decoded)`. Fixed two ways, because either alone leaves a hole:
the resolver also drops a trailing `-XXXX` after the extension, and the thumbnail now decodes
`hs.pasteboard.readImage()` — the bytes just *proved* to be on the board — instead of a path that
may already have been renamed out from under it. The click target stays a path, resolved by inode
at click time, seconds later, when the final name certainly exists.

**2. The Targets table's "10 ms poll + ≤ 1 ms PNG write + verify" budget was measured on the wrong
pasteboard.** D2's sub-millisecond figure is a *private* board written from an AppKit process.
Measured here through `hs.pasteboard`: write + read-back of 351 KB is **0.43 ms on a private board
and 3–19 ms on the GENERAL one**, and 19.6 MB is 8.7 ms private. The difference is not size, it is
that every write to the general board notifies this machine's clipboard observers. The p100 budget
has to carry that term; it is the second-largest on the path after the file read.

**3. 🚨 The unattended bench cannot measure thumbnail visibility AT ALL, and the reason is its own
presence gate.** 180 s of idle is exactly what makes this Mac sleep the display and lock the
screen — so the canvas is *genuinely* occluded behind the lock window, `isOccluded()` is right to
keep saying so, and `phase=thumb-visible` never fires. Worse, polling for it was the single largest
load the bench placed on the window server (150 `CGWindowListCopyWindowInfo` round trips per
iteration, ending 1.5 s before the next capture), and that perturbation alone moved
`png-complete→copied` **p100 between 26 and 53 ms across otherwise identical runs**. `winprobe`
now reports `CGSSessionScreenIsLocked`, `run.py` records the metric as unmeasurable instead of
polling for it, and `analyze.py` says so in the output. **Consequence for the Targets table: the
`capture → thumbnail fully visible ≤ 200 ms p50` row cannot be certified by an unattended run and
needs an operator-attended one** (`--min-idle 0` with somebody watching). The live keyboard shots
above are the only real evidence so far: `thumb-shown` 6–24 ms after `copied`, `thumb-visible`
30–91 ms after that.

### The performance work, and one optimisation that was built and refuted

The first passing configuration measured `png-complete→copied` p50 42.7 / p100 60.7 ms on ~8 MB
captures. Four changes took it to **p50 ≈ 20 / p100 25.6–27.1 ms**, each one benched rather than
reasoned about:

| change | why | effect |
|---|---|---|
| a **sized** `f:read(size)` instead of `read("*a")` | `"*a"` cannot know the length, so Lua doubles a `luaL_Buffer` and copies through every realloc; 19.6 MB measured 24.83 / 8.46 / 9.98 ms against 2.61 / 3.23 / 3.14 ms sized | p50 42.7 → 25.9 ms |
| **two rates, one timer**: settle every 5 ms, directory stat every 10 ms, settle first in the tick | once a candidate is open the only question is whether IEND has landed, and each tick of interval *T* adds *T*/2 on average to a 30 ms budget; an lseek + 8-byte read is 0.17 ms | p100 44.7 → 30.9 ms |
| `hs.pasteboard` joins the warm list (F2 §9) | `hs` loads an extension on first ACCESS, and the copy path was paying for it: across three runs the FIRST capture was the slowest every time, 30.9 / 31.0 ms against a 26.1 ms worst case for the other nine | p100 30.9 → 29.8 ms |
| the bench stops polling for an impossible answer (finding 3) | it was the largest load in its own measurement | p100 spread 26–53 → 25.6–27.1 ms |

**Refuted, and recorded in `hsc/screenshot/settle.lua` so it is not re-attempted:** an *amortized*
reader that takes each tick's new bytes as they land and concatenates at the end. The streaming
temp is append-only, so it is sound — and it measured **p50 25.3 vs 25.9 ms (no change) and p100
44.7 vs 39.1 ms (worse)**. The residual cost is I/O, not buffer growth: a **cold** 8.7 MB PNG reads
in 11.12 ms through this path and a **warm** re-read of the same file in 2.96 ms, so the bytes
genuinely have to come off the device and chunking only adds ~8 MB of garbage for the collector to
walk at the worst possible moment.

### A fourth finding, and it validates the rule it tested

**`hs.ipc`'s replaced `print` raises, and it reaches the poll.** 42 `phase=error` lines appeared
across this session, all of them inside reload windows and **none during the 14-minute unattended
acceptance run**, with messages pointing at `hs/ipc.lua:81`, `hs/_coresetup.lua:26` and
`hs/logger.lua:189` — a stale IPC port makes the replaced `print` raise, formatting that error
prints again, and the recursion is the stack overflow. Zero screenshots were lost to any of them,
because the poll's callback is inside a `pcall` and its timer carries `continueOnError`, and
because nothing in this config calls `print` or `hs.logger` and so never originates one. This is
the same mechanism that killed the config on 2026-09-10 at 12:03:36 (`EXC_BREAKPOINT` inside
hs.ipc's logger) — unguarded there, contained here. The Phase 5a rule "no bare `print`; write
through `hsc/log.lua`" is not stylistic.

### Invariants confirmed live

- `phase=armed dir=… entries=3425 expect=3425 invariant=holds size=109600` — the **corrected**
  step 2b(a) predicate (`name count == st_size/32`, because `hs.fs.dir` yields `.` and `..`) is
  right on this volume, and the code prints both numbers exactly as Phase 2 demanded rather than
  assuming either. The watcher degrades to its full 10-tick bound if they ever disagree.
- **Idle listing rate 1.00 per second and nothing else** — the backstop alone, with `ticks` climbing
  at ~98/s on the 10 ms directory poll (12 591 ticks over 128.77 s of uptime). Under bench load:
  **3.9–4.3 listings per shot**, inside the decision log's budget.
- **`phase=renamed` routinely lands seconds after `phase=copied`** — the whole point of the phase,
  visible in the log on every shot.

### Still open after W1 + W3

Critic items **6, 8 and 10** are untouched and owned by W4/W5 (items 1 and 2 are W2's and it
reports them closed on `main`). Item **11** is partly
addressed — the bench samples a full-display capture every 20 iterations and `analyze.py` reports
percentiles per size band — but the *base* band is now the pessimistic end of the distribution
rather than the p85 image, because a locked screen's photographic wallpaper compresses to ~8 MB
where a UI screenshot of the same geometry is ~2.4 MB. Phase 1 and Phase 6 landed from W2 while this wave
was running, so failure class A is no longer open — but nothing in W1 depends on that, and the
acceptance numbers below were taken with supervision already live.

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
- **Clipboard before decode; no slide.** The PNG bytes need no decode, the thumbnail's decode is
  the copy path's real cost on big captures (E1), and a `:show(0.12)` fade is a window-server
  animation with none of the timer state that produced two shipped bugs.
- **10 ms poll, no helper — settled by measurement, not by preference (C1, 88 % conviction).** A
  kernel watcher is genuinely faster (p50 0.503 / p99 4.224 ms vs 4.705 / 11.050 ms) but the whole
  prize is ~4 ms p50 / ~7 ms p99 against a 16 ms Apple write and a 250 ms slide-in, and it costs a
  permanent-deafness failure mode on directory replacement plus a second unsupervised process. The
  residual 12 % is C1 §12: no real ⌘⇧4 keyboard shot occurred inside a watch window (the lifecycle
  was a faithful reproduction of KB §F2, not Apple's own bytes), and the main-thread contention that
  most threatens the poll was measured on a proxy rather than on a busy Hammerspoon — both close in
  the Phase 5 bench.
- **The poll's signature is `st_size` alone.** This is the one-line change C1 rates the
  highest-value line in its axis: it closes a live blind spot (failure mode 14 — ~3 % of shots at
  the shipped 50 ms poll, one production instance at 6 026 ms) *and* cuts the poll's listing load.
  Safe only in combination with triggering on creation rather than on the final name — which is
  exactly what Phase 2 does, plus the 1 Hz backstop of step 1b for the net-zero tick.
  **Budget, stated so it does not contradict step 2b (critic item 12):** the target is
  **1 listing per shot on an uncontested scan, ≤ N on a contested one (N = the 2b bound), plus 1/s
  from the backstop** — *not* the flat "23.35 → 1.00" C1 measured on a synthetic run without a
  reconcile loop. Phase 3's acceptance row must read that way too, and `analyze.py` must **print
  observed listings-per-shot** so the real number is measured after landing rather than inherited.
- **KeepAlive with ThrottleInterval=1, Login Item removed, Sparkle auto-update off** — the three
  together are what "exactly one instance, back in under a second" requires.
  **(Superseded on the throttle by K3, as shipped 2026-09-13: the DEFAULT ThrottleInterval — a mature
  job re-forked in 49 ms end to end at the default; `=1` would only turn a start-up crash into a 1 Hz
  loop.)**
- **Bounded retroactivity (15 s at arm)** replaces "never retroactive": the 2026-09-08 rationale
  (do not overwrite what the user has since copied) holds for old files, not for a shot taken
  during a 2 s restart.
- **Retire the fallback** rather than fix it: every fix leaves the throttle/age interaction or the
  older-over-newer race in place, and supervision makes its window ~2 s.
- **Hotkey takeover rejected** (dead key when Hammerspoon is dead; spawner nag), **native capture
  rejected** (loses the crosshair/magnifier/window mode), **FSEvents rejected** (2026-09-08).
- **The settle runs at 5 ms while the directory poll stays at 10 ms (W1, measured).** These are
  different questions: detection asks "is there a new entry", which the 10 ms interval was
  benchmarked for, while the settle asks "has IEND landed on a file I already hold open", which
  costs an lseek and 8 bytes. Giving both the same interval spent 10 ms of a 30 ms budget on the
  cheaper question. One timer at 5 ms, the directory stat every second tick, settle first.
- **The thumbnail decodes the pasteboard, not a path (W1).** A capture wears three names while we
  hold it; the one it was caught under may be gone by the time anything decodes. `readImage()` uses
  the bytes we just verified, and the click target is resolved by inode at click time instead.
- **An amortized reader was built and refuted (W1).** See § W1 acceptance record — the residual
  cost is I/O, not Lua buffer growth, and the chunked version measured worse at p100. Do not
  re-open it without a measurement that beats 19.9 ms p50 / 27.1 ms p100 on ~8 MB captures.
- **The bench records thumbnail visibility as UNMEASURABLE rather than polling for it (W1).** Its
  own 180 s presence gate is what locks the screen, so the canvas is genuinely occluded and no
  amount of polling can produce the answer — while the polling itself was the largest load in the
  measurement. That target now needs an operator-attended run.

## Verification ledger (updated as the wave lands)

| claim | verifier verdicts | status |
|---|---|---|
| K1 mds XPC timeout after the PNG is complete | mechanism **stands, 80 %**; measurement **REFUTED, 88 %** — the two lenses split | Blocking call is MDItemSetAttributes; the stall is unbounded (13.7 s, 29.4 s seen) — no 10 s assumption anywhere (Phase 2 cap 30 s; Phase 6). **Three framing corrections adopted:** (1) the 30-day tail is contaminated by this investigation's own CLI bursts — the user baseline is the 547 non-probe shots (p90 94 ms, p99 2.9 s, ≥1 s 2.6 %), not p99 9.9 s; the lenses disagree on the share (≤2 of 29 events vs 3–5× inflation) and it stays unresolved. (2) Only 6 of 29 ≥1 s stalls are ~10 s timeouts; 22 are slow completions. (3) **The stall is a TAIL, not the median** — median share of capture→clipboard is 61 %, and the worst measured shot (6.1 s) was 44 ms Apple + 6,089 ms *ours*, the same shot C1 traced to failure mode 14. **The median is Phases 2–4's to fix, not Apple's.** |
| K2 hidden temp, same inode, bytes final at mtime | **stands** — mechanism 85 %, measurement 88 % (two independent refuters, 0.5 ms hashing pollers, binary call-site analysis, 18 joined keyboard shots) | corrections adopted: three-name lifecycle (`..X.png-XXXX` → `.X.png` → final), the race is a MISS not a wrong image, fd-open remedy in Phase 2 steps 2–5, gain qualified (median 5–10 ms; ≥ 1 s in 4.6 %; 10 s in 1 %) |
| K3 KeepAlive/ThrottleInterval/TCC/double-launch | **refuted 85 % / 80 %** — KeepAlive respawns a mature job in ~1 ms at the DEFAULT throttle; TI=1 only shortens crash-loop backoff | Phase 1 keeps the default ThrottleInterval; downtime bound is Hammerspoon's own start (~0.6–2 s) |
| K4 st_size invariant, 10 ms timer, inode dedup at verified copy | **refuted 90 % / 90 %** — the invariant holds and sharpens (size = 32 × (entries + 2), moving only with the NET entry count, name-length independent), but it detects a count change ONCE and a 7 ms listing races Apple's two renames (~5 % of shots) | Phase 2 scan re-lists until inode count == size/32 − 2 and opens each new inode by its current name |
| K5 PNG-only pasteboard suffices for Claude Code | **stands 88 % / 85 %** | Claude Code's native module asks for public.png first; osascript PNGf is its fallback |
| K6 SIGTERM by the census bug; nothing restarts Hammerspoon | cause **stands 85 %**; three details corrected (one ~2 s pass, 76 kills; 875/878 was the next-day reproduction) | KB §F1/§F9 |
| gap-fill B1 / E1 / F1 (+addendum) / D2 | **delivered** and integrated (Phases 1, 2, 4, 5, 7) | — |
| completeness critic (Z) | **delivered** (14 KB, fresh context, 0 captures) — 12 ranked gaps, own measurements | 3 were defects in this plan and are **corrected above** (Phase 2 step 1b net-zero backstop; step 2b predicate off-by-two + wrong key + ~10× budget; decision-log listings budget). 8 remain open with owners in § Completeness critic — **items 1, 3 and 2 are pre-landing gates on W2, W1 and W4** |
| gap-fill B2 (screencapture internals) | **delivered** (31 KB, disassembly) and integrated (Phase 2 preamble, Phase 7 item 1, KB §F2) | The stall is an unguarded straight-line call (`sub_100019794`), so no preference or exclusion can remove it — the dotfile copy is the ONLY fix. Three constraints adopted: **Esc cancels with exit 0** (never use the exit code as a capture verdict), `screencapture` does not exit until after the rename, and `show-thumbnail=0` is a precondition rather than a constant. `-c` cannot stall and writes exactly one flavor — D2 §7 upgraded from reasoned to static |
| gap-fill F2 (main-thread blockers) | **delivered** (40 KB, live Hammerspoon at load 33–39) and integrated (Phase 3 rewritten, KB §F4 rewritten) | **Refutes this plan's own magnitudes**: the Dock rebind runs ≈2×/day, not continuously, and five headline figures (20 ms `getCurrentScreen`, 3.9 ms `getByName`, 8.6 ms `plist.read`, 7 ms listing, 27–60 µs stat) were **first-call module-load artifacts**. The rebind is still removed — for its **unbounded** tail (`hs.execute` has no timeout), not its mean. Real per-shot cost is ~120 ms of image work. The eventtap **self-heals**; the settle loop's repeated read is latent until Phase 2 lands. New: warm the lazy modules at load (~20–40 ms off the first shot after every relaunch) |
| W2 Phase 1 live proof (2026-09-13) | **measured on the real job**, not the `/bin/sleep` proxy | `--prove`: respawn **49 ms**, detector downtime **565 ms** (kill → armed), 1 instance; K3's "mature job re-forks fast at the default throttle" confirmed on Hammerspoon itself; TCC intact under launchd provenance (critic item 1 closed) |
| gap-fill C1 (kqueue helper vs the poll) | **delivered** (32 KB, conviction 88 %) and integrated (Phase 2 step 1, Phase 7 item 3, decision log) | Helper **rejected on its own numbers** (~4 ms p50 / ~7 ms p99 saved, for a permanent-deafness failure mode + a second unsupervised process). The axis's real yield is the opposite finding: the **shipped** `mtime:ctime:size` signature has a structural blind spot — ~3 % of shots at the 50 ms poll, one production instance at 6 026 ms (KB §F7, failure mode 14) — closed by the one-line `st_size`-only signature |

## Completeness critic (Z, 2026-09-11) — what must close before these phases can honestly promise 100.00 %

A fresh-context critic read the KB, this plan, all 17 gap-fill reports and the K1–K6 verdict JSON,
ran **0 screencapture captures**, and ranked what is missing by risk to the 100.00 % / p100 claim.
Items 4, 5 and 12 were **defects in this document** and are already corrected above (Phase 2 steps 1b
and 2b, and the decision-log budget). The rest are open and owned here. `[E-mine]` = the critic's own
measurement.

| # | Gap | Why it bites | Cheapest close |
|---|---|---|---|
| **1** | **Phase 1's premise has never been run once.** Every Phase 1 number comes from a `/bin/sleep` proxy, and both K3 lenses state the TCC half is reasoned, untested | Launch provenance demonstrably decides which grants apply — a Hammerspoon exec'd from a terminal is attributed to **the terminal** (`tccd … responsible={net.kovidgoyal.kitty}`) `[E]`. `Program`-launching an `.app` binary outside LaunchServices is the one provenance nobody has exercised. If the launchd instance comes up without Accessibility, the ⌘V→⌃V tap is dead — **and step 2 has already deleted the Login Item, so the rollback path is the thing that just failed** | One operator-attended install with `supervise.sh uninstall` staged, asserting `hs.accessibilityState()`, `hs.screenRecordingState()`, the `poll armed` line and one real ⌘V — **before** step 2 removes the Login Item, not after |
| **2** | **"Hammerspoon cannot start" has no owner, and Phase 6 removes the only thing covering it** | Default `ThrottleInterval` (correct, per K3) turns a start-up crash into a **6-relaunch/minute GUI loop forever** — no `SuccessfulExit` key, no sentinel, no notification. Not hypothetical: the live instance died of `EXC_BREAKPOINT` in `hs.ipc`'s logger on 2026-09-10 12:03:36, and a second instance's `init.lua` aborted at line 5. W1 lands new Lua into that same start path; W4 retires the fallback | Make the plist's `Program` a `supervise.sh --run` wrapper that refuses a 4th launch in 60 s, writes a breadcrumb and `hs.notify`s; **gate W4 on 7 days of clean supervision**, not on surviving one `launchctl kill TERM` |
| **3** | **The keyboard path's hidden-name lifecycle has still never been observed live** — and the plan closes that only *after* landing | Phase 2 steps 2/2b/3/9 all key on it. If the keyboard path differs in a temp directory, a third rename, or its first 8 bytes at first sight, **W1 ships a detector that silently drops every real shot while the CLI bench prints `lost 0/300`.** Open question 1 defers this to "log the first real shot after landing" — validating the central premise with the artifact built on it | Before W1 lands: arm C1's already-built `…/c1-work/bin/kqwatch <dir> scan` (or a 5 ms hashing poller), operator takes **one** ⌘⇧4 shot, join to the unified log. One shot, zero CLI captures |
| **6** | **Loss is unfalsifiable by the instrument the acceptance uses** | L1 is "0 real shots without a `copied` record", and `phase=lost` comes from a deadline timer **that only exists once a shot was detected**. Every failure class that matters — dead, crash-looping, blind — yields *neither* `copied` *nor* `lost`. Already true on disk: two shots from 2026-09-10 1.33 PM have **zero log lines of any kind** `[E-mine]` | A 5-minute launchd auditor doing the join that already found the 6 026 ms outlier (file birth times vs `copied` lines), notifying on a non-empty delta, and reading **a heartbeat file rather than `pgrep`** — the 12:03 incident proved a live pid is not a live pipeline |
| **7** | **⌘⇧5 is a live modality here and nobody has measured its writer** | `Screen Recording 2026-09-04 at 1.07.44 PM.mov` is in `~/Screenshots` and `video = 1` in the defaults `[E-mine]`. B2 derived the lifecycle from `/usr/sbin/screencapture`, but `name`/`style`/`target`/`type` are read by **`screencaptureui`**, and its floating-thumbnail toggle re-introduces a second, user-paced move. The 30 s window, the handle-through-renames settle and the 30 s cap are all unvalidated for that writer | Read `show-thumbnail` and `target` at module start, **WARN on any value but `0`/`file`**, and take one ⌘⇧5 selection shot once the Phase-2 log emits hidden names |
| **8** | **A file-less capture modality sits inside the 100.00 % claim but outside the committed phases** | Ctrl-held ⌘⇧4 and ⌘⇧5→clipboard produce **no file**, so there is no Pop and no thumbnail and the user reads it as failure. Leaving it "Phase 7, optional" makes the headline metric **false by construction** for a modality the machine supports | Either promote Phase 7 item 2 into W1 (`hs.pasteboard.watcher`: foreign `changeCount` carrying `public.png`, no new file within 300 ms ⇒ thumbnail from the pasteboard), **or write the modality out of the frozen scope in one line** so the metric means what it says |
| **9** | **A second clipboard writer is running right now and nothing detects it** | `VoiceInk.app` pid 52167 is live `[E-mine]` — exactly G1 item 10's class. User shoots, dictates, VoiceInk restores its own snapshot, ⌘V pastes text — **and the log still reads `copied`, so the 7-day acceptance scores it a success** | After the verified write, one `changeCount` re-check at +300 ms; if it moved and we did not move it, log `clobbered`. One timer, ~5 µs |
| **10** | **The user-visible end — ⌘V landing an image in Claude Code — is never measured** | L1/L2 stop at `sha1(pasteboard public.png) == sha1(file)`. Downstream: the tap drops events during a stall (duration unresolved), any browser copy hijacks ⌘V in terminals, and **Claude Code resizes anything wider than 2000 px** (`maxWidth:2000…`, ~140 ms) — while two of the last eight real shots are 3456 px wide `[E]` | One bench row reading the board back through **the same path Claude Code's fallback uses** (`osascript «class PNGf»` → temp → sha); and state in writing that the eventtap and foreign-writer classes are either in scope or out |
| **11** | **The p100 latency targets are calibrated on a p85 image** | Every target derives from the 2516×1926 / 2.4 MB capture — **percentile 84.7** of 3,377 shots, with p99 = **5120×2880 / 20.6 MB** `[E]`. At that size the PNG-only pasteboard write alone is **3.00 ms p50** against 0.71 ms, and the thumbnail decode scales with pixels. **A p100 target defended by a p85 sample is not a p100 target**, and the bench's fixed `-R` rect keeps it that way | Make the bench's rect schedule sample the real distribution (≥ 1 full-display iteration per 20) and report targets **per size band** |

**Explicitly not re-spent** (already verified, or already honestly stated as a limit): K2's hidden-name
mechanism; K1's unbounded stall; K3's ~1 ms mature respawn; K4's ±32 invariant; K5's PNG-only
sufficiency; the `-R`-is-not-the-keyboard-path caveat; the bench's mds-contamination caveat;
`fullScreenAuxiliary` (W3); the Darwin-notification question (open question 5).

🚨 **Gating consequence for Phase 0's wave order.** Items 1 and 3 are **pre-landing** gates on W2 and
W1 respectively, and both need one operator-attended minute. Item 2 changes W4's gate from an event
to a duration. These are not "nice to have before shipping" — each one is a path where the wave lands
green and the pipeline is silently worse than today.

**Disposition as W2/W4 shipped (2026-09-13).** Item 1 — **CLOSED, and made mechanical**: every
`supervise.sh install` asserts `hs.accessibilityState()`, `hs.screenRecordingState()` and
`hs.eventtap` on the launchd-started instance before deleting the Login Item, rolling back on any
failure; live result `true,true,true`, then two real ⌘⇧4 shots (8:43:29 and 8:44:44 PM) were
`copied` by that same launchd pid. The "one real ⌘V" half is not assertable from a script and was
not separately observed; the tap's precondition (Accessibility + a live `hs.eventtap`) was. Item 2 —
**W4 gated on `--prove` per the dispatch brief, not on 7 days**; the crash-loop residual is recorded
under Phase 6's status and stays owned by item 6's auditor.

## Risks and rollbacks

| risk | mitigation / rollback |
|---|---|
| launchd-spawned Hammerspoon loses a TCC grant | grants are keyed to the signed bundle (measured holdings in KB §F6); `supervise.sh uninstall` restores the Login Item in one command |
| a second instance appears (Sparkle, Login Item re-added by an installer) | single-instance guard logs and exits the non-launchd instance |
| a dotfile that is not a screenshot lands in `~/Screenshots` | PNG signature + 30 s creation window; anything else is logged and ignored |
| the 10 ms poll costs CPU under extreme load | 0.6 % of a core measured; the timer interval is one constant |
| a consumer needs TIFF | `SCREENSHOT_TIFF=true` re-enables a delayed second write |
| the bench perturbs the operator | idle guard, pointer-movement abort, clipboard snapshot/restore, self-cleaning files |
| **the launchd instance comes up without Accessibility/Screen Recording** (critic 1 — never exercised; launch provenance decides grants) | operator-attended first install with `supervise.sh uninstall` staged, asserting both TCC states + one real ⌘V **BEFORE** the Login Item is deleted — never after |
| **a start-up crash becomes an unbounded 6/min relaunch loop** with the fallback already retired (critic 2) | `supervise.sh --run` wrapper refuses a 4th launch in 60 s + breadcrumb + `hs.notify`; W4 gated on 7 days clean, not one kill test |
| **the detector silently drops every real shot while the bench prints `lost 0/300`** (critic 3 — the keyboard lifecycle is still unobserved live) | one operator ⌘⇧4 under `kqwatch scan` **before** W1 lands; never validate the premise with the artifact built on it |
| **a shot produces neither `copied` nor `lost`, so the 7-day metric cannot see it** (critic 6; two such shots already on disk) | 5-minute launchd auditor joining file birth times to `copied` lines, heartbeat file not `pgrep` |
| **another app clobbers the clipboard after our verified write** (critic 9 — VoiceInk is live now) | `changeCount` re-check at +300 ms; log `clobbered` so the acceptance stops scoring it a success |
| **⌘⇧5 / floating-thumbnail writer invalidates the settle assumptions** (critic 7 — `video=1` on this box) | read `show-thumbnail`/`target` at start, WARN on anything but `0`/`file` |

## Open questions (owner, closing action)

1. ~~Keyboard-path temp spelling — W1 (log the first real shot's names after landing).~~
   **ANSWERED 2026-09-13, and by two real shots rather than one.** Both hidden forms were observed
   live by the landed pipeline — `.Screenshot 2026-09-13 at 8.43.29 PM.png` and
   `..Screenshot 2026-09-13 at 8.44.44 PM.png-NKr8` — in the spelling KB §F2 predicts, with
   `renamed` following 0.3–0.5 s later. This also closes completeness critic item 3. See
   § W1 acceptance record.
2. Clipboard destination skips `mds`? — W5 experiment 1 (operator presses Ctrl+⌘⇧4 once).
3. `fullScreenAuxiliary` over fullscreen Spaces — W3 bench.
4. What loads `mds` — B1 (pending), then claude-infrastructure.
5. **Does `screencapture` post a Darwin notification?** — would beat both the poll and the rejected
   helper at zero cost. Cheapest close (C1 §12): `notifyutil -w` on candidate names while one shot is
   taken. Untested; nobody has looked.
6. **Population miss-rate of the current signature** — C1's ~1.5 % (10 ms) / ~3 % (50 ms) is modelled
   from n=190 synthetic cycles against n=1 production instance. After the `st_size`-only signature
   lands, the poll's own log makes it directly countable (W3 bench).
7. **`hs.reload()` toward a running `hs.task` child** — untested (reload was forbidden during C1);
   matters only if the helper is ever revived, but an orphaned child would accumulate silently.
   Close by reading Hammerspoon's `libtask.m` teardown, or one operator-run reload probe.
