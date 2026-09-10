# ⌘⇧4 → clipboard + thumbnail — knowledge base (measured 2026-09-10)

**Question.** The ⌘⇧4 drag screenshot is supposed to land on the clipboard (so Claude Code accepts
it on ⌘V) and show a thumbnail bottom-right, every time, within a beat. It does neither 100 % of
the time and sometimes takes seconds. Why, measured — and what a 100.00 % / 100th-percentile
pipeline has to look like. The plan built on this file: `docs/plans/SCREENSHOT_PIPELINE_100P.md`.

**One paragraph.** Three independent causes, all measured on this machine. (1) Hammerspoon — the
only thing that copies and draws — was **dead for 5.4 hours** last night: a fleet script SIGTERMed
875 of 878 user processes at 18:55:16, Hammerspoon is a plain Login Item with nothing supervising
it, and the launchd fallback that took over lost 3 of the 9 screenshots taken while it was down.
(2) Apple's own `screencapture` writes the finished PNG within ~35 ms of the capture and then
**blocks on a synchronous Spotlight (`mds`) call with a 10-second timeout** before it renames the
file into its final name — the poll only matches the final name, so in 4.6 % of shots the clipboard
and thumbnail wait ≥ 1 s and in 1.1 % exactly 10 s, on a machine whose Spotlight server is kept
busy by the Claude fleet. (3) Hammerspoon's own contribution after the rename is small but not
100th-percentile: a 50 ms poll quantum, a 7 ms listing of 3,374 entries, a 55 ms TIFF re-encode of
a big capture, a synchronous python3 spawn on every Dock change, and a 250 ms slide-in.

---

## 1. The system as built (2026-09-08 → 2026-09-10)

| Component | Where | Role |
|---|---|---|
| macOS 15.7.9, 10 cores, 64 GB, load avg 22–26 | — | host; the Claude Code fleet keeps load high and Spotlight busy |
| `/usr/sbin/screencapture` (SystemUIServer launches it for ⌘⇧4, `launched with keyboard.selection`) | Apple | crosshair UI, capture, PNG write, Spotlight stamp, rename |
| `~/Screenshots` (3,374 entries; APFS reports st_size = 32 B × entries) | — | landing directory (`defaults com.apple.screencapture location`, `show-thumbnail=0`) |
| Hammerspoon 1.1.1 (`init.lua` 636 lines, symlinked from this repo) | this repo | 50 ms stat() poll → settle → PNG+TIFF to pasteboard → Pop → hs.canvas thumbnail |
| `~/Library/Logs/Hammerspoon/screenshot.log` | Hammerspoon | ms-timestamped `detected` / `copied … settled Nms` lines |
| launchd agent `com.chrisren.screenshot-clipboard` (WatchPaths → `~/bin/screenshot-to-clipboard.sh`) | claude-infrastructure | fallback clipboard writer when Hammerspoon is not running (PNG only, no thumbnail) |
| Claude Code 2.1.260 (`~/.claude-260/…/bin/claude.exe`) | consumer | on ⌃V runs `osascript -e 'the clipboard as «class PNGf»'`, saves to `$TMPDIR/claude_cli_latest_screenshot.png`, reads it |
| Hammerspoon eventtap ⌘V→⌃V in terminals (kitty, iTerm2, Ghostty, WezTerm, Terminal) | this repo | lets the user press ⌘V; Claude Code sees ⌃V |

The filename timestamp (`Screenshot 2026-09-09 at 11.59.59 PM.png`, U+202F before AM/PM) is the
moment the **hotkey was pressed**; the capture happens at mouse-up (unified log `Capturing image`),
1.3–9.5 s later while the user drags. All latencies below are measured from the capture, i.e. from
the file's birth time (birth = capture + ~30 ms).

## 2. Instruments and their traps

- **Filesystem timestamps are the primary record.** APFS keeps birth (`st_birthtime`), mtime and
  ctime with ns precision for every screenshot ever taken here (n = 3,369 since 2025-12). For a
  screenshot: birth = temp file created ≈ capture + 30 ms; mtime = last byte written; ctime =
  the rename into the final name (a same-directory rename updates ctime, not mtime).
- **`screenshot.log`** gives `detected` (poll saw the final name) and `copied` (pasteboard write
  verified) with ms timestamps. Its `Ns old` field was `now − mtime`, i.e. it measured Apple's stall,
  not our latency — a misleading name, replaced in the plan.
- **Unified log**: `/usr/bin/log show --predicate 'process == "screencapture"'` (the bare `log` is a
  shell builtin here; wrap in `timeout 150`). It records `launched with keyboard.selection`,
  `Capturing image`, every XPC connection the process opens, and its exit — the whole Apple-side
  timeline to the millisecond. `mds` logs `XPC_TIMEOUT SERVER SIDE, 10000` when it drops a request.
- **In-process probes** via `hs -c 'return dofile(...)'`: schedule work with `hs.timer.doAfter`,
  store results in a global, read them back in a second call. A call that blocks the main thread
  for more than a few seconds loses the IPC reply and the transport then drops replies
  intermittently for a while ("receive timeout", "dropping corrupt reply Mach message") — read
  results back with a retry, never trust an empty reply as "no result".
- **`hs.pasteboard` argument order** is `writeAllData([name], table)`, `readDataForUTI([name], uti)`
  — name first; `writeObjects(object, [name])` — object first.
- **A throwaway launchd agent** (`/bin/sleep`, label `com.hs-research.keepalive-probe`) measured
  KeepAlive semantics without touching the real jobs; it was booted out afterwards.
- **Never** synthesize keyboard/mouse input while the operator is at the keyboard (HIDIdleTime was
  0.07 s during this investigation); never write the general pasteboard from a probe.

## 3. Findings

### F1 — Hammerspoon was dead for 5.4 h, and nothing restarts it (reliability class A)

- launchd: `application.org.hammerspoon.Hammerspoon…[1961]: exited due to SIGTERM | sent by
  zsh[66592]` at 2026-09-09 18:55:16.312; runningboardd `termination reported by launchd (2, 15, 15)`.
  No crash report exists; it was not memory pressure (runningboardd: "not memory-managed"), not
  Sparkle, not a logout.
- Cause (peer record, claude-infrastructure `docs/research/mass-app-termination-2026-09-09.md`): a
  Claude session's process census `LA_PAT='…' ps … | awk -v p="$LA_PAT" 'index($0,p)'` bound the
  variable to `ps` only, `awk` saw an empty pattern, `index($0,"")` matched every line, and the kill
  loop SIGTERMed 875 of 878 user processes in three waves (Kitty, Dia, Discord, Chrome,
  Hammerspoon, ~17 Claude sessions, most launchd agents). Prior mass-kill incidents on this box are
  recorded in claude-infrastructure `hooks/lib/kill-selection.py` (2026-08-09, 08-25, 09-04). A
  hook gate now denies that command shape — but the fleet has killed Hammerspoon before and can again.
- Hammerspoon is a Login Item (`System Events` lists it, path `/Applications/Hammerspoon.app`) with
  **no launchd job, no KeepAlive**. It stayed dead until this investigation relaunched it at
  00:20:18 (`open -a Hammerspoon`; the log then reads `screenshot poll armed … 3374 entries known`).
- While it was dead, 9 screenshots were taken. The fallback agent's run durations against the
  file timestamps show which it copied (a ≥ 0.7 s run = it slept 0.5 s and ran osascript) and which
  it dropped (a ≤ 0.2 s run = the age guard exited):

| capture (birth) | final name at (ctime) | fallback launch → exit | verdict |
|---|---|---|---|
| 21:50:13.865 | 21:50:13.944 | 21:50:13.975 → 15.249 (1.27 s) | copied, PNG only, ~1.3 s late, no thumbnail |
| 22:56:50.577 | 22:56:50.603 | 22:56:50.685 → 51.945 (1.26 s) | copied |
| 23:12:44.789 | 23:12:44.807 | 23:12:44.961 → 47.178 (2.22 s) | copied |
| 23:44:00.748 | 23:44:00.765 | 23:44:00.956 → 02.142 (1.19 s) | copied |
| 23:44:04.734 | 23:44:04.751 | 23:44:11.789 → 12.514 (0.72 s) | copied 7 s late (launchd 10 s throttle) |
| 23:44:18.160 | 23:44:18.176 | 23:44:22.162 → 23.309 (1.15 s) | copied 4 s late |
| 23:59:31.614 | 23:59:31.982 | 23:59:31.718 → 33.617 (1.90 s) | ran the copy; outcome unverifiable — the clipboard at 00:03 still held the 11:44:15 image |
| 23:59:47.502 | 23:59:51.416 (3.9 s stall) | 23:59:47.610 → 47.803 (0.19 s), 23:59:58.425 → 58.587 (0.16 s) | **LOST**: first launch saw only the older file (age 16 s → exit); the launch after the rename was throttled to +10 s and found the file 11.2 s old → exit |
| 00:00:02.953 | 00:00:12.984 (10.0 s stall) | 00:00:08.964 → 09.143, 00:00:19.079 → 19.196 | **LOST**: same mechanism — launchd's 10 s `ThrottleInterval` × the script's 10 s recency guard × Apple's 10 s stall |

  The fallback has run 3,414 times since it was installed; it is a WatchPaths job, so it also
  depends on fseventsd (which livelocked for a day on 2026-09-07/08), and its `*.png` glob skips
  the dotfile temp, so it always waits out Apple's stall too.

### F2 — Apple stalls up to 10 s on Spotlight AFTER the PNG is complete (latency class A)

The unified log of the 23:59:59 capture (pid 85239), with the file's own timestamps:

| t (2026-09-10) | event |
|---|---|
| 23:59:59.748 | `launched with keyboard.selection` (hotkey pressed; filename time) |
| 00:00:02.923 | `Capturing image` … `captureRect = (1267, 167, 461, 828)` (mouse-up) |
| 00:00:02.933 | connects to `SystemSoundServer` (shutter sound) |
| 00:00:02.950 | connects to **`com.apple.metadata.mds`**; `unable to get a dev_t for store 1795162192` |
| 00:00:02.953 | file birth (`.Screenshot … .png`, hidden temp) |
| 00:00:02.969 | file mtime — **the PNG is complete** (211,603 bytes, IEND present) |
| 00:00:02.951 → 00:00:12.965 | silence: blocked in the synchronous mds XPC |
| 00:00:12.964 | `mds[634]: =-=-=-= XPC_TIMEOUT SERVER SIDE, 10000` |
| 00:00:12.965 | connects to `com.apple.metadata.mdwrite` (writes `kMDItemIsScreenCapture`, `kMDItemScreenCaptureGlobalRect` xattrs) |
| 00:00:12.984 | file ctime — **renamed to the final name**; process exits at 12.969–12.984 |
| 00:00:19.079 | (fallback agent launch, throttled; Hammerspoon dead) |

- Distribution of that stall (ctime − mtime) over every screenshot: last 30 days, n = 611 — p50
  11 ms, p75 27 ms, p90 225 ms, p95 0.92 s, p99 9.9 s, max 13.7 s; **4.6 % ≥ 1 s, 1.1 % ≈ 10.0 s**.
  All-time (n = 3,369): 83 % < 0.1 s, 3.3 % 0.1–1 s, 2.8 % 1–5 s, 0.5 % 5–10 s, 0.1 % the 10 s
  timeout; the ≥ 10 s class first appears in 2026-08 (1) and 2026-09 (4 of 77), i.e. as the fleet's
  load grew. The PNG write itself is never the problem: birth→mtime p50 16 ms, p99 162 ms, max 4.3 s.
- It is not fixable by excluding the directory from Spotlight: 15 of 15 CLI captures
  (`screencapture -x -R … <file>`) into an indexed folder, a `.noindex` folder and `/tmp` **all**
  opened the `com.apple.metadata.mds` connection. The call is made per file regardless of index
  state; only its latency varies with mds's health (0.13 s vs 1.2 s vs 10 s for the same command).
- The `mds` server on this box: pid 634 at ~20 % CPU, `mds_stores` ~36 % CPU / 2.4 GB RSS, a
  continuous stream of CoreDuet context fetches and "Failed to resolve entitled attributes" for
  short-lived client pids. `~/.claude` (a dot-directory) is not indexed (`mdfind` count 0). Which
  processes are loading it is a fleet-side question (gap-fill axis B1; see §6).
- **The image is available 10 s before the rename.** During the stall the complete PNG sits in
  `~/Screenshots` under its hidden temp name (`.Screenshot … .png`; the CLI equivalent measured
  as `.life.png` → `life.png`, same inode, 25 ms apart when mds was fast). The current matcher
  (`^Screenshot…png$`) ignores dotfiles, so the pipeline waits for Apple. 0 stranded dotfiles exist
  among 3,374 entries, so the rename always eventually lands.

### F3 — Hammerspoon's own path after the rename (latency class B)

Every real keyboard screenshot since the poll landed on 2026-09-08 (n = 20), ms:

| shot | PNG write | Apple stall | rename→detected | detected→copied | capture→copied | bytes |
|---|---|---|---|---|---|---|
| 09-08 8.32.21 AM | 94 | 168 | 27 | 79 | 368 | 2,378,621 |
| 09-08 9.36.58 AM | 30 | 76 | 74 | 30 | 210 | 252,664 |
| 09-08 9.41.50 AM | 59 | **10,030** | 21 | 53 | 10,163 | 757,228 |
| 09-08 9.41.58 AM | 54 | 3,382 | 112 | 41 | 3,589 | 739,283 |
| 09-08 3.47.41 PM | 53 | 18 | 5 | 26 | 102 | 579,370 |
| 09-08 3.49.18 PM | 29 | 17 | 22 | 19 | 87 | 628,454 |
| 09-08 6.12.49 PM | 59 | 23 | 107 | 57 | 247 | 742,998 |
| 09-08 9.00.04 PM | 39 | 29 | 23 | 37 | 129 | 443,231 |
| 09-08 10.58.07 PM | 87 | 445 | 74 | 66 | 672 | 1,901,960 |
| 09-08 11.43.48 PM | 18 | **10,008** | 38 | 16 | 10,081 | 142,624 |
| 09-08 11.43.55 PM | 16 | 2,879 | 19 | 102 | 3,016 | 145,675 |
| 09-09 12.26.10 PM | 17 | 167 | 33 | 23 | 239 | 246,498 |
| 09-09 12.27.13 PM | 44 | 5 | 31 | 39 | 119 | 562,955 |
| 09-09 12.27.22 PM | 26 | 98 | 40 | 29 | 193 | 367,855 |
| 09-09 12.27.41 PM | 42 | 202 | 21 | 47 | 312 | 549,544 |
| 09-09 12.44.07 PM | 26 | 86 | 82 | 28 | 223 | 333,378 |
| 09-09 12.48.26 PM | 5 | 4,432 | 22 | 14 | 4,473 | 47,662 |
| 09-09 1.06.23 PM | 67 | 532 | 24 | 55 | 678 | 424,638 |
| 09-09 1.46.50 PM | 25 | 60 | 92 | 31 | 208 | 320,673 |
| 09-09 6.35.06 PM | 3 | 199 | 6 | 12 | 221 | 46,330 |
| **p50 / p90 / max** | 35 / 69 / 94 | 167 / 4,989 / 10,030 | 29 / 94 / 112 | 34 / 67 / 102 | 243 / 5,034 / 10,163 | |

- `rename→detected` is the 50 ms poll quantum plus the 7 ms listing plus main-thread contention
  (max 112 ms when two shots landed together). `detected→copied` scales with image size: the PNG
  read and decode are ~1 ms, the **TIFF re-encode is 55 ms for 2516×1926** (19.4 MB TIFF) versus
  0.5 ms for the PNG-only pasteboard write (measured in-process on a private pasteboard).
- Then the thumbnail: a 250 ms slide-in at 15 fps (timer loop), so the user sees it settle
  ~300 ms after the copy; the Pop sound is played before the canvas is built.
- The poll's cost: `stat()` 60 µs; listing 3,374 entries 7.0 ms; `hs.timer` jitter under load 22:
  10 ms → p50 10.0 / p99 11.0 / max 11.1 ms; 16 ms → max 18.2 ms; 50 ms → max 51.1 ms. A 10 ms poll
  is therefore stable and costs 0.6 % of a core.

### F4 — Main-thread hazards (reliability class B)

- `rebind()` (Dock shortcuts) runs `hs.execute(python3 …)` **synchronously** on every
  `com.apple.dock.plist` change: 54 ms at load 22, seconds at load 200+. `hs.plist.read` reads the
  same plist natively in 8.6 ms (7 persistent-apps, `file-label`/`bundle-identifier` intact).
  Frequency is low (0 Dock-plist events in a 188 s window, 18 other prefs writes), but each one
  stalls the poll and every settle timer; a >1 s stall also disables the ⌘V→⌃V eventtap by timeout
  (hostile review item 6).
- The "hot second" rescans (every other tick while the directory's mtime is the current second)
  cost up to ~10 listings × 7 ms per changed second; at a 10 ms poll they would be 50 × 7 ms = 35 %
  of a core. The redesign removes the need for them (§F7).
- The settle loop reads the whole PNG every 50 ms while waiting (`f:read("*a")`, up to 3 MB); a
  tail-8-byte IEND check is microseconds.
- `hs.image.imageFromPath` is lazy (0.5–0.9 ms); decoding happens when the canvas renders.

### F5 — What Claude Code needs from the pasteboard (correctness)

From the 2.1.260 binary (byte offsets 160386945–160387905, `v={darwin:{checkImage:…,saveImage:…}}`):
`checkImage = osascript -e 'the clipboard as «class PNGf»'`; `saveImage = osascript -e 'set png_data
to (the clipboard as «class PNGf»)' -e 'set fp to open for access POSIX file "<tmp>/claude_cli_latest_screenshot.png" with write permission' -e 'write png_data to fp' -e 'close access fp'`
(temp dir overridable with `CLAUDE_CODE_TMPDIR`); file-URL clipboards are read with `the clipboard
as «class furl»`; text with `pbpaste` (2 s timeout); large images are byte-budget compressed
(`tengu_image_compress_failed`). So a pasteboard carrying `public.png` is exactly what it consumes;
TIFF is never asked for. The pasteboard server also advertises translations of a PNG-only write
(`clipboard info` after the fallback's PNG-only osascript listed PNGf, 8BPS, GIF, jp2, JPEG, TIFF,
BMP, TPIC), so legacy TIFF readers are served without us encoding one. Claude Code's own read costs
two `osascript` spawns after ⌃V — outside this repo's control.

### F6 — Supervision semantics (measured with a throwaway agent)

| launchd configuration | respawn after SIGTERM/SIGKILL |
|---|---|
| `KeepAlive=true`, default `ThrottleInterval` (10 s), job younger than 10 s | 9.1–10.1 s (launchd waits for 10 s since the job started) |
| `KeepAlive=true`, `ThrottleInterval=1`, job 1 s old | **0.05 s** |
| `KeepAlive=true`, `ThrottleInterval=1`, job 11 s old | **0.04 s** |

`launchctl kill TERM gui/$UID/<label>` signals by label (no pid variables — the fleet's empty-selector
gate rejects `kill "$var"` shapes). Hammerspoon's bundle is `LSUIElement=1`, id
`org.hammerspoon.Hammerspoon`, TeamIdentifier `VQCYSNZB89`; TCC grants are keyed to that signed
identity, so a launchd-spawned instance keeps Accessibility and Screen Recording (it holds
`kTCCServiceScreenCapture` auth 2 since 2026-02-16, and `hs.screenRecordingState()` is true —
devil's-advocate report). Sparkle 2.6.4 is set to `SUAutomaticallyUpdate=1`, and the Login Item
still exists — both can launch a second instance outside launchd (hostile review item 3).

### F7 — Filesystem invariants the redesign rests on (measured on this volume)

| operation in a directory | st_size | mtime | ctime |
|---|---|---|---|
| create dotfile temp | 64 → 96 (**+32**) | changed | changed |
| append bytes to it | same | same | same |
| rename dotfile → final (same dir) | same | changed | changed |
| case-only rename | same | changed | changed |
| xattr write on a file | same | same | same |
| rename INTO the dir from a sibling dir | **+32** | changed | changed |
| hard link / delete | **+32 / −32** | changed | changed |
| create + rename in one step | **+32** | changed | changed |
| utime / overwrite in place | same | same | same |

The inode is stable across the rename (`889053410 → 889053410`); `hs.fs.attributes` exposes `ino`
and `creation` (birth time) besides the whole-second `modification`/`change`. So **creation is
always visible in st_size** (no dependence on second-resolution timestamps), and only the rename is
invisible to the size — which the redesign makes non-critical (it re-points a path).

### F8 — Adversarial review of the redesign (two frontier-tier reports, verbatim in the scratchpad)

Hostile reviewer, ranked: (1) copying from the dotfile adds one new silent-loss race — the rename
can land between two settle polls, `settleStep` reports "gone", and an inode recorded at detection
would then skip the final name as a duplicate; mitigation: record the inode only on verified copy
and, on "gone", re-resolve the same inode under its new name. (2) A size-stable fallback becomes a
corruption path for a dotfile whose write plateaus; use IEND only. (3) KeepAlive + Login Item +
Sparkle = two instances. (4) The arm-time window: a shot during Hammerspoon's 1–2 s start is marked
"known" and never copied — copy anything created ≤ 15 s ago at arm time. (5) Ctrl-held and
⌘⇧5 → clipboard captures produce no file and are invisible; `hs.pasteboard.watcher` can draw a
thumbnail from the pasteboard. (6) A main-thread stall > ~1 s disables the ⌘V→⌃V tap. (7) Any
final-named entry hijacks the clipboard (Finder "Screenshot … copy.png"); require creation ≤ 30 s.
(8) The fallback agent can land an older PNG over a newer shot inside the relaunch window — retire
it. (9) `screencapture -R` is not the keyboard path (temp spelling, spawn path) and `hs -c` is an
unreliable transport for a bench — measure from the file log. (10) Rotate the log on write; unhide
a stranded dotfile after 30 s; play Pop after the thumbnail; verify `fullScreenAuxiliary` behaviour
over fullscreen Spaces; Wispr Flow/VoiceInk also write the clipboard around dictation.

Devil's advocate (should Hammerspoon own the hotkey?): a takeover (`screencapture -i -c` under a
Hammerspoon binding) would be fast and TCC is not a blocker, but a dead Hammerspoon then means a
dead key, and a spawned capture accrues Sequoia's periodic "bypass the private window picker"
prompt via `replayd`/`ScreenCaptureApprovals.plist`. Verdict: **hybrid at most** — keep the system
hotkey as owner; optionally point its destination at the clipboard (`com.apple.screencapture`
`target clipboard`, i.e. what Ctrl+⌘⇧4 does) so Apple fills the pasteboard directly and Hammerspoon
polls `changeCount`, draws the thumbnail and writes the archive file off the critical path. The one
experiment that decides it: one Ctrl+⌘⇧4 with a 10 ms changeCount probe armed and the unified log
open — no `com.apple.metadata.mds` line and a changeCount bump ~100 ms after `Capturing image`
means the clipboard path skips the stall entirely. 14 days of logs contain zero clipboard-mode runs.

## 4. Failure-mode catalogue (every way a shot fails today, and its status)

| # | failure | today | after the plan |
|---|---|---|---|
| 1 | Hammerspoon not running (killed / quit / crashed) | silent; fallback copies PNG only, late, and loses rapid or stalled shots | launchd KeepAlive restarts in < 1 s; bounded retroactive copy at arm; fallback retired |
| 2 | Apple's post-write Spotlight stall (≤ 10 s) | clipboard + thumbnail wait for the rename | copy from the dotfile temp on IEND; the stall no longer reaches the user |
| 3 | Rename lands between settle polls (dotfile design only) | n/a | inode recorded on verified copy; "gone" re-resolves by inode |
| 4 | Main thread blocked (python Dock rebind, TIFF encode, hot rescans) | poll and tap stall; tap can be disabled by timeout | native plist read; PNG-only write; no hot rescans; nothing synchronous on the poll path |
| 5 | 50 ms poll quantum + 7 ms listing | 29 ms median, 112 ms max after the rename | 10 ms poll; listing only on a size change |
| 6 | Shot during Hammerspoon start (1–2 s) | marked known, never copied | copy entries created ≤ 15 s ago at arm |
| 7 | Finder-created "Screenshot … copy.png" or a sync client hijacks the clipboard | copied as if new | require creation within 30 s and PNG signature |
| 8 | Ctrl-held / ⌘⇧5 → clipboard capture (no file) | no thumbnail, no Pop (user reads "failed") | optional: pasteboard watcher draws the thumbnail from the pasteboard |
| 9 | Two Hammerspoon instances (Login Item + launchd, or Sparkle relaunch) | n/a | Login Item removed, `SUAutomaticallyUpdate=0`, single-instance guard |
| 10 | Fallback agent races a restarted Hammerspoon and lands an older image | possible inside the relaunch window | retired |
| 11 | FSEvents/fseventsd livelock | fixed 2026-09-08 (poll) | unchanged — the poll asks the kernel |
| 12 | Thumbnail stranded / dismissed by a click on its predecessor | fixed 2026-07-21 | unchanged |
| 13 | Log grows without bound at a 10 ms poll error rate | truncated only at load | rotate on write, rate-limit errors |

## 5. Architecture options and the deciding facts

| option | latency after capture | survives a dead Hammerspoon? | verdict |
|---|---|---|---|
| **A. file-watch + dotfile early copy (chosen)** | PNG complete +16 ms p50 → ≤ 10 ms poll → ≤ 1 ms write ≈ **30–60 ms p50, ~200 ms p99** (bounded by Apple's write of big captures) | yes: the file still lands; the clipboard is restored within seconds of the relaunch | keeps Apple's UI, Apple's archive naming and Spotlight metadata; no new permissions; every step measured here |
| B. hybrid: hotkey destination = clipboard, Hammerspoon polls changeCount and writes the archive | Apple writes the pasteboard directly; probably no mds call (unmeasured) | clipboard yes; **archive file NO** while Hammerspoon is down | worth one experiment; changes the user's archive semantics and must discriminate screenshots from other image copies |
| C. Hammerspoon owns ⌘⇧4 (`screencapture -i` via hs.task) | ~50–100 ms; exact completion callback | **no** — dead key | rejected: dead-key failure mode, Sequoia's spawner nag, unproven eventtap visibility |
| D. native capture (`hs.screen:snapshot`, own crosshair UI) | 33–86 ms | no | rejected: loses the system crosshair/magnifier/window mode; the nag by design |
| E. kqueue/dispatch-vnode helper instead of the poll | saves ≤ 10 ms over a 10 ms poll | n/a | not worth a compiled dependency yet; measured jitter makes the poll sufficient (gap-fill axis C1 pending) |
| F. FSEvents (`hs.pathwatcher`) | — | — | rejected 2026-09-08: went blind for a day; 5 of 13 shots lost |

## 6. Open questions and what closes each

| question | why it matters | cheapest closing action |
|---|---|---|
| Exact temp-name spelling on the keyboard path (`.Screenshot … .png` observed 2026-09-08; CLI shows `.name.png`) | the matcher must not depend on it | match any new regular file by PNG signature + creation time, not by name spelling (design choice); confirm once from the 10 ms poll's own log after landing |
| Does the clipboard destination (`-c` / Ctrl-held) skip the mds call? | decides whether option B beats A on latency | the one-shot experiment in §F8, when the operator is present |
| What loads `mds` on this box? | fleet-wide cost; Finder/Spotlight suffer too | gap-fill axis B1 (pending); hand to claude-infrastructure |
| Any consumer that needs `public.tiff`? | PNG-only is the fast path | pasteboard translations cover TIFF readers (§F5); keep a one-line switch to add TIFF |
| kqueue helper vs 10 ms poll | ≤ 10 ms | gap-fill axis C1 (pending) |
| Thumbnail primitive costs (canvas build, 60 fps slide vs fade) | the last ~250 ms the user perceives | gap-fill axis E1 (pending); measured in the bench after landing |

## 7. Reproduce

```bash
# the Apple-side timeline of the last screenshot
timeout 150 /usr/bin/log show --last 1h --predicate 'process == "screencapture" OR (process == "mds" AND eventMessage CONTAINS "XPC_TIMEOUT")' --style compact
# stall distribution (ctime−mtime) over every screenshot
python3 - <<'EOF'
import os,re;d=os.path.expanduser('~/Screenshots');xs=sorted(os.stat(f'{d}/{n}').st_ctime-os.stat(f'{d}/{n}').st_mtime for n in os.listdir(d) if re.match(r'Screenshot .*\.png$',n))
p=lambda q:xs[int((len(xs)-1)*q)];print(len(xs),'p50',p(.5),'p90',p(.9),'p99',p(.99))
EOF
# is Hammerspoon alive, and did the last shot copy?
pgrep -x Hammerspoon; tail -n 4 ~/Library/Logs/Hammerspoon/screenshot.log
# launchd respawn timing on this box (throwaway agent, see §F6)
```

Provenance: measurements 2026-09-10 00:00–00:50 and 08:15–08:40 CDT on this machine; adversarial
reports `G1-hostile-reviewer.md`, `G2-devils-advocate.md` (session scratchpad); the peer record
`~/Development/claude-infrastructure/docs/research/mass-app-termination-2026-09-09.md`; the
previous investigation `docs/TROUBLESHOOTING.md` and commits `fd706a9`, `e2220ac`.
