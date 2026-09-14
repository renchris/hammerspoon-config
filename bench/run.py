#!/usr/bin/env python3
"""bench/run.py — the acceptance driver for the ⌘⇧4 pipeline.

ONE long-lived process drives the whole run.  A process per sample would cost more than the thing
being measured, and the native helper (bench/winprobe.swift) is likewise started once and driven
over a pipe.

WHAT IT MEASURES, AND WHAT IT HONESTLY CANNOT
---------------------------------------------
`screencapture -x -R` reproduces the keyboard path's FILE WRITES byte for byte and in sequence
(verified n=11): the same single CGImageDestinationCreateWithURL call site serves both, so the
three-name lifecycle, the inode, the Spotlight stall and the rename are identical.  What it does
NOT reproduce is the interactive phase — there is no crosshair, no drag and no mouse-up — so every
number here is `capture-spawn → …`, never `hotkey → …`.  The keyboard path itself is proven by real
use: every real shot leaves a `copied` line naming its hidden-name lifecycle.

`-R` also contacts `mds` on every capture, which means a 300-sample run loads the very daemon whose
stall is under study.  The run therefore reports its OWN observed stall rate against the 30-day
baseline (2.6 % ≥ 1 s on the 547 non-probe shots; 4.6 % on the contaminated full sample) as a
validity check, and spaces captures ≥ 2 s.

🚨 THE EXIT CODE IS NOT A VERDICT.  Escape cancels with exit status 0 (keycode 0x35 branches to
`mov w0,#0; bl _exit`), and an asleep display is exit 1 with nothing written.  Success here is
always tested on the ARTIFACT.

🚨 THE PROBER IS A FALSIFIER, NEVER A CLOCK.  `phase=thumb-visible` is emitted in-process from
hs.canvas:isOccluded(); winprobe exists to contradict it.  Its own scheduling gap reaches 89 ms
under this load, so a disagreement > 100 ms fails the iteration and its timestamps are never
subtracted to produce a latency.
"""

import argparse, json, os, re, shutil, signal, subprocess, sys, time, uuid

HOME = os.path.expanduser("~")
DEFAULT_DIR = os.path.join(HOME, "Screenshots")
DEFAULT_LOG = os.path.join(HOME, "Library/Logs/Hammerspoon/screenshot.log")

# The rect schedule samples the REAL size distribution rather than one image.  Every target in the
# plan was calibrated on a 2516×1926 / 2.4 MB capture, which is percentile 84.7 of 3,377 real shots
# — p99 is 5120×2880 / 20.6 MB, where the PNG-only pasteboard write alone is 3.00 ms against
# 0.71 ms.  A p100 target defended by a p85 sample is not a p100 target (completeness critic 11), so
# one iteration in FULL_EVERY is a full-display capture.
FULL_EVERY = 20
BASE_RECT = (240, 120, 1258, 963)      # points; ≈ the p85 image at 2× backing scale


def log(msg):
    print(f"[bench] {msg}", flush=True)


class Probe:
    """The native helper, held open for the whole run."""

    def __init__(self, binary):
        self.p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, bufsize=1)

    def cmd(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        out = self.p.stdout.readline()
        if not out:
            raise RuntimeError("winprobe died")
        return json.loads(out)

    def close(self):
        try:
            self.p.stdin.write("quit\n"); self.p.stdin.flush()
            self.p.wait(timeout=3)
        except Exception:
            self.p.kill()


class LogTail:
    """Incremental reader over hsc/log.lua's logfmt output.

    The format is a contract: fixed leading keys, bare values, and `file=` LAST so a basename with
    spaces needs no quoting.  Lines are joined to captures by `id=` — six hex characters of the
    INODE — because that is the only identifier that survives Apple's two renames.
    """

    FIELD = re.compile(r"(\w[\w-]*)=(.*?)(?=\s+\w[\w-]*=|$)")

    def __init__(self, path):
        self.path = path
        self.fh = open(path, "r", errors="replace")
        self.fh.seek(0, os.SEEK_END)
        self.ino = os.fstat(self.fh.fileno()).st_ino
        self.lines = []

    def _reopen_if_rotated(self):
        """hsc/log.lua rotates at 1 MB ON WRITE, and a 300-sample run adds ~500 KB.

        A tail that holds the old handle keeps reading the renamed file and sees nothing further —
        which this harness would report as every remaining shot being SILENT, i.e. lost. So the
        inode is checked, and on a rotation the new file is read from the beginning (the lines we
        want cannot be older than the rotation).
        """
        try:
            st = os.stat(self.path)
        except OSError:
            return
        if st.st_ino == self.ino:
            return
        try:
            self.fh.close()
        except OSError:
            pass
        self.fh = open(self.path, "r", errors="replace")
        self.ino = os.fstat(self.fh.fileno()).st_ino
        log("log rotated mid-run — reopened the tail on the new file")

    def poll(self):
        self._reopen_if_rotated()
        for line in self.fh:
            line = line.rstrip("\n")
            if not line:
                continue
            rec = {}
            for m in self.FIELD.finditer(line):
                rec[m.group(1)] = m.group(2)
            if rec:
                rec["_raw"] = line
                self.lines.append(rec)
        return self.lines


def ino_id(ino):
    return format(ino % 0x1000000, "06x")


def mono_of_realtime_ns(rt_ns):
    """Convert a kernel-recorded wall-clock timestamp to the monotonic clock the log uses.

    hs.timer.absoluteTime(), mach_absolute_time() and time.monotonic_ns() are the same clock with no
    offset (measured), and APFS records mtime at microsecond resolution — so the PNG's own mtime is
    the capture-complete instant with no poller in the loop.  The offset is re-sampled per use
    because it is only stable while the machine stays awake.
    """
    off = time.clock_gettime_ns(time.CLOCK_REALTIME) - time.monotonic_ns()
    return rt_ns - off


def preflight(args, probe):
    problems = []
    pids = subprocess.run(["/usr/bin/pgrep", "-x", "Hammerspoon"], capture_output=True, text=True)
    n = len([p for p in pids.stdout.split() if p.strip()])
    if n != 1:
        problems.append(f"expected exactly 1 Hammerspoon process, found {n}")
    if not os.path.isdir(args.dir) or not os.access(args.dir, os.W_OK):
        problems.append(f"{args.dir} is not a writable directory")
    if not os.path.exists(args.log):
        problems.append(f"{args.log} does not exist — is the pipeline running?")
    # An asleep display is exit 1 with nothing written, and that path never touches Spotlight —
    # so it is a PRECONDITION, tested here, not a result to be discovered on the first capture.
    disp = probe.cmd("display")
    if disp.get("asleep") or disp.get("displays", 0) < 1:
        problems.append("the display is asleep (screencapture would exit 1 writing nothing) — "
                        "hold `caffeinate -d` before the idle window opens")
    return problems, n


def wait_for_file(path, deadline_s):
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.01)
    return False


def capture(path, rect, stall_s=0.0, hidden_hint=None):
    """Spawn screencapture.  Returns (t_spawn_mono_ns, returncode).

    In --stall mode the child is SIGSTOPped as soon as its hidden file appears — i.e. between the
    complete PNG and the rename — which is exactly where Apple's Spotlight call sits.  A pipeline
    that copies from the dotfile must produce `copied` long before `renamed`.
    """
    t0 = time.monotonic_ns()
    proc = subprocess.Popen(["/usr/sbin/screencapture", "-x",
                             "-R%d,%d,%d,%d" % rect, path])
    if stall_s > 0 and hidden_hint:
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if os.path.exists(hidden_hint):
                try:
                    os.kill(proc.pid, signal.SIGSTOP)
                    time.sleep(stall_s)
                    os.kill(proc.pid, signal.SIGCONT)
                except ProcessLookupError:
                    pass
                break
            time.sleep(0.005)
    rc = proc.wait()
    return t0, rc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("n", nargs="?", type=int, default=300)
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--log", default=DEFAULT_LOG)
    ap.add_argument("--probe", default=os.path.join(os.path.dirname(__file__), "winprobe"))
    ap.add_argument("--out", default=None, help="write the per-iteration records here as JSON")
    ap.add_argument("--min-idle", type=float, default=180.0,
                    help="required hs.host.idleTime()/HID idle before the run may start")
    ap.add_argument("--abort-idle", type=float, default=5.0,
                    help="abort before the next capture if idle falls below this")
    ap.add_argument("--spacing", type=float, default=2.0, help="minimum seconds between captures")
    ap.add_argument("--deadline", type=float, default=15.0,
                    help="seconds to wait for phase=copied|lost")
    ap.add_argument("--stall", type=float, default=0.0,
                    help="SIGSTOP the capture child for N seconds between the PNG and the rename")
    ap.add_argument("--stall-every", type=int, default=0,
                    help="apply --stall to every Nth iteration (0 = never)")
    args = ap.parse_args()

    if not os.path.exists(args.probe):
        log(f"FAIL: prober not built at {args.probe}")
        return 2

    probe = Probe(args.probe)
    problems, hs_n = preflight(args, probe)
    if problems:
        for p in problems:
            log(f"FAIL preflight: {p}")
        probe.close()
        return 2

    # PRESENCE GATE.  The bench takes screenshots of the operator's live desk and owns the general
    # pasteboard for the duration; running it while they are working is both a perturbation and a
    # measurement error.
    # A locked screen makes thumbnail visibility unobservable — and polling for it anyway is not
    # merely useless, it is the largest load the bench puts on the window server: 150 round trips
    # per iteration that cannot succeed, ending 1.5 s before the next capture. Measured, that
    # perturbation moved png-complete→copied p100 between 26 and 53 ms across otherwise identical
    # runs. The metric is recorded as unmeasurable instead.
    locked = bool(probe.cmd("display").get("locked"))
    if locked:
        log("screen is LOCKED — thumb-visible is unobservable this run and will not be polled")

    idle = probe.cmd("idle")["idle"]
    if idle < args.min_idle:
        log(f"ABORT: operator present (idle {idle:.0f}s < {args.min_idle:.0f}s required)")
        probe.close()
        return 3

    snap_path = f"/tmp/screenshot-bench-clipboard-{os.getpid()}.plist"
    snap = probe.cmd(f"snapshot {snap_path}")
    if not snap.get("ok"):
        log(f"ABORT: {snap.get('error', 'cannot snapshot the clipboard')}")
        probe.close()
        return 3
    log(f"clipboard snapshot: {snap['items']} item(s), types={snap.get('types', [])}")

    run_id = uuid.uuid4().hex[:8]
    tmpdir = f"/tmp/screenshot-bench-{run_id}"
    os.makedirs(tmpdir, exist_ok=True)
    tail = LogTail(args.log)
    baseline_pointer = probe.cmd("pointer")
    records = []
    aborted = None

    log(f"run {run_id}: n={args.n} dir={args.dir} spacing={args.spacing}s")

    try:
        for i in range(args.n):
            # ABORT ON PRESENCE, before the capture rather than after it.
            ptr = probe.cmd("pointer")
            idle_now = probe.cmd("idle")["idle"]
            if (abs(ptr["x"] - baseline_pointer["x"]) > 2 or abs(ptr["y"] - baseline_pointer["y"]) > 2
                    or idle_now < args.abort_idle):
                aborted = f"operator returned at iteration {i} (idle {idle_now:.1f}s)"
                log(f"ABORT: {aborted}")
                break

            # Unique per run AND per iteration.  A name is only reconsidered once it leaves the
            # listing, and reusing one would make any dedup mistake look like a clean pass.
            name = f"Screenshot BENCH {run_id} {i:04d}.png"
            path = os.path.join(args.dir, name)
            hidden = os.path.join(args.dir, "." + name)
            rect = (0, 0, 0, 0)
            if FULL_EVERY and i % FULL_EVERY == FULL_EVERY - 1:
                rect = (0, 0, 3000, 2000)     # clipped to the display by screencapture
                band = "full"
            else:
                rect = BASE_RECT
                band = "base"

            stall = args.stall if (args.stall_every and i % args.stall_every == 0) else 0.0
            t_spawn, rc = capture(path, rect, stall, hidden)

            if not wait_for_file(path, 35.0):
                records.append({"i": i, "name": name, "band": band, "outcome": "no-artifact",
                                "rc": rc, "note": "no file — display asleep, cancelled, or blocked"})
                log(f"  {i}: NO ARTIFACT (rc={rc}) — aborting the run")
                aborted = "no artifact produced; display asleep or capture blocked"
                break

            st = os.stat(path)
            rec = {
                "i": i, "name": name, "band": band, "rc": rc, "stall_requested_s": stall,
                "ino": st.st_ino, "id": ino_id(st.st_ino), "bytes": st.st_size,
                "t_spawn_mono": t_spawn,
                "png_complete_mono": mono_of_realtime_ns(st.st_mtime_ns),
                "apple_stall_ns": st.st_ctime_ns - st.st_mtime_ns,
            }

            # WAIT FOR A VERDICT, not for a timeout.  `phase=lost` is emitted by a deadline timer,
            # so a loss is a positive record; a shot that produces NEITHER is counted separately
            # because that is the failure class the instrument itself cannot see (critic 6).
            deadline = time.monotonic() + args.deadline
            outcome, phases = None, {}
            while time.monotonic() < deadline:
                for line in tail.poll():
                    if line.get("id") != rec["id"]:
                        continue
                    ph = line.get("phase")
                    if ph and ph not in phases:
                        phases[ph] = int(line.get("mono", 0))
                    if ph == "copied":
                        # The copied line carries its own cost breakdown; keep it, because where
                        # the milliseconds went is the question every latency finding turns on.
                        for k in ("read_ns", "pb_write_ns", "pb_verify_ns", "write_ns", "seq"):
                            if k in line:
                                rec[k] = int(line[k])
                    if ph in ("copied", "lost"):
                        outcome = ph
                if outcome:
                    break
                time.sleep(0.01)
            rec["phases"] = phases
            rec["outcome"] = outcome or "silent"

            if outcome == "copied":
                sha_file = subprocess.run(["/usr/bin/shasum", "-a", "1", path],
                                          capture_output=True, text=True).stdout.split()[0]
                board = probe.cmd("pngsha")
                rec["sha_file"] = sha_file
                rec["sha_board"] = board["sha1"]
                rec["board_len"] = board["len"]
                rec["bytes_match"] = (board["len"] == st.st_size and board["sha1"] == sha_file)

                # The falsifier.  Poll for geometric visibility and compare with the in-process
                # line — but only while an answer is possible, and only until the in-process line
                # has already been corroborated.
                seen = None
                if locked:
                    rec["thumb_unmeasurable"] = "screen-locked"
                else:
                    vis_end = time.monotonic() + 1.0
                    while time.monotonic() < vis_end:
                        p = probe.cmd("probe")
                        if p["visible"]:
                            seen = p["t"]
                            break
                        time.sleep(0.02)
                rec["probe_visible_mono"] = seen
                if seen and "thumb-visible" in phases:
                    rec["probe_disagreement_ms"] = abs(seen - phases["thumb-visible"]) / 1e6

            # Clean up OUT of the watched directory.  A create and an unlink inside one poll tick
            # cancel in st_size (Δ 0, measured n=20), and the bench must not manufacture the failure
            # it is grading — so the file leaves immediately after its verdict and is deleted
            # elsewhere, well clear of the next capture's 2 s spacing.
            try:
                shutil.move(path, os.path.join(tmpdir, name))
                os.remove(os.path.join(tmpdir, name))
            except OSError as e:
                rec["cleanup_error"] = str(e)

            records.append(rec)
            mark = {"copied": "ok", "lost": "LOST", "silent": "SILENT"}.get(rec["outcome"], "?")
            if "copied" in phases and "created" in phases:
                dt = (phases["copied"] - rec["png_complete_mono"]) / 1e6
                log(f"  {i:4d}/{args.n} {mark:6s} png→copied {dt:7.1f} ms  {st.st_size/1024:7.0f} KB {band}")
            else:
                log(f"  {i:4d}/{args.n} {mark:6s} (no copied line)")

            if i + 1 < args.n:
                time.sleep(max(0.0, args.spacing))
    finally:
        res = probe.cmd(f"restore {snap_path}")
        log(f"clipboard restored: ok={res.get('ok')} types={res.get('types')}")
        probe.close()
        try:
            os.remove(snap_path)
            shutil.rmtree(tmpdir, ignore_errors=True)
        except OSError:
            pass

    payload = {
        "run_id": run_id, "requested": args.n, "completed": len(records),
        "screen_locked": locked,
        "aborted": aborted, "mode": "bench", "spacing_s": args.spacing,
        "min_idle_s": args.min_idle, "deadline_s": args.deadline,
        "hammerspoon_instances": hs_n,
        "records": records,
    }
    out = args.out or f"/tmp/screenshot-bench-{run_id}.json"
    with open(out, "w") as f:
        json.dump(payload, f, indent=1)
    log(f"records → {out}")
    print(out)
    return 0 if not aborted else 4


if __name__ == "__main__":
    sys.exit(main())
