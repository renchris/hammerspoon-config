#!/usr/bin/env bash
# scripts/screenshot-bench.sh — the one command that proves the pipeline.
#
#   bash scripts/screenshot-bench.sh --quick 10     # a smoke run
#   bash scripts/screenshot-bench.sh 300            # the acceptance run + its document
#
# What it does, in order:
#   1. builds bench/winprobe.swift if the binary is missing or stale;
#   2. POINTS ~/.hammerspoon/init.lua AT THIS CHECKOUT for the duration and reloads — and restores
#      it on ANY exit path, recording both steps in the pipeline's own log, because a measurement of
#      the wrong tree is worse than no measurement;
#   3. puts the pipeline in bench mode (no sound, 0.4 s dismissal);
#   4. runs bench/run.py, then bench/analyze.py;
#   5. at N ≥ 50 writes docs/research/screenshot-acceptance-<date>.md.
#
# 🚨 It NEVER executes the Hammerspoon binary directly.  Launching
# /Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon starts a SECOND instance that displaces
# the live one — that is how the config died on 2026-09-10 at 12:03:36.  Reloads go through
# `hs -c 'hs.reload()'`.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINK="$HOME/.hammerspoon/init.lua"
LOG="$HOME/Library/Logs/Hammerspoon/screenshot.log"
PROBE_SRC="$REPO/bench/winprobe.swift"
PROBE_BIN="$REPO/bench/winprobe"

N=300
QUICK=0
MIN_IDLE=180
GATE_WAIT=${GATE_WAIT:-600}
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; N="${2:-10}"; shift 2 ;;
    --no-relink) RELINK=0; shift ;;
    --min-idle) MIN_IDLE="$2"; EXTRA+=(--min-idle "$2"); shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    [0-9]*) N="$1"; shift ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done
RELINK="${RELINK:-1}"

note() { printf '[bench] %s\n' "$*"; }

# One logfmt line, written by the bench itself, so the symlink swap is on the record next to the
# measurements it made possible.
logline() {
  mkdir -p "$(dirname "$LOG")"
  printf 'ts=%s mono=0 phase=%s src=bench %s\n' \
    "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" "${2:-}" >> "$LOG"
}

# ---------------------------------------------------------------------------- prober
if [[ ! -x "$PROBE_BIN" || "$PROBE_SRC" -nt "$PROBE_BIN" ]]; then
  note "building winprobe"
  swiftc -O -o "$PROBE_BIN" "$PROBE_SRC"
fi

# ---------------------------------------------------------------------------- display
# 🚨 THE IDLE GATE AND THE DISPLAY FIGHT EACH OTHER, AND THE DISPLAY WINS BY DEFAULT.  The bench
# may not start until the machine has been idle 180 s — but this Mac's display sleeps inside that
# window, and an asleep display makes `screencapture` exit 1 having written nothing at all
# (measured: "could not create image from display with rect …", both of the knowledge base's own
# capture probes, and this bench's first --quick 10 attempt).  So the run HOLDS `caffeinate -d`
# for its whole lifetime.  It asserts the display assertion only; it posts no events, so the idle
# clock keeps climbing underneath it and the presence gate still means what it says.
CAFFEINATE_PID=""
start_caffeinate() {
  caffeinate -d -i -w $$ &
  CAFFEINATE_PID=$!
  note "holding caffeinate -d (pid $CAFFEINATE_PID) for the duration"
}
stop_caffeinate() { [[ -n "$CAFFEINATE_PID" ]] && kill "$CAFFEINATE_PID" 2>/dev/null; }
start_caffeinate

display_asleep() {
  printf 'display\nquit\n' | "$PROBE_BIN" | \
    /usr/bin/python3 -c 'import sys,json; print("1" if json.loads(sys.stdin.readline())["asleep"] else "0")' 2>/dev/null
}
read_idle() {
  printf 'idle\nquit\n' | "$PROBE_BIN" | \
    /usr/bin/python3 -c 'import sys,json; print(int(json.loads(sys.stdin.readline())["idle"]))' 2>/dev/null
}
if [[ "$(display_asleep)" == "1" ]]; then
  # Waking it necessarily resets the idle clock — there is no way to wake a display without
  # declaring user activity — so the run serves the presence gate again.  With -d held it will
  # not sleep a second time, which is what makes the second wait terminate.
  note "display asleep; waking it (this resets the idle clock, so the gate is re-served)"
  caffeinate -u -t 1
  sleep 2
  gate_deadline=$(( $(date +%s) + GATE_WAIT ))
  while [[ "$(read_idle)" -lt "$MIN_IDLE" ]]; do
    if [[ "$(date +%s)" -ge "$gate_deadline" ]]; then
      note "ABORT: idle never reached ${MIN_IDLE}s within ${GATE_WAIT}s — the operator is present"
      exit 3
    fi
    sleep 10
  done
  note "idle gate re-served at $(read_idle)s"
fi

# ---------------------------------------------------------------------------- symlink
ORIGINAL=""
restore_link() {
  if [[ -n "$ORIGINAL" ]]; then
    ln -sfn "$ORIGINAL" "$LINK"
    logline warn "msg=bench-symlink-restored target=$ORIGINAL"
    note "restored ~/.hammerspoon/init.lua -> $ORIGINAL"
    hs -c 'hs.reload()' >/dev/null 2>&1 || true
    sleep 3
  fi
}
trap 'restore_link; stop_caffeinate' EXIT INT TERM

if [[ "$RELINK" == "1" ]]; then
  if [[ -L "$LINK" ]]; then
    CURRENT="$(readlink "$LINK")"
  else
    CURRENT=""
  fi
  if [[ "$CURRENT" != "$REPO/init.lua" ]]; then
    ORIGINAL="$CURRENT"
    logline warn "msg=bench-symlink-pointed target=$REPO/init.lua was=${CURRENT:-none}"
    ln -sfn "$REPO/init.lua" "$LINK"
    note "pointed ~/.hammerspoon/init.lua -> $REPO/init.lua (was ${CURRENT:-not a symlink})"
    hs -c 'hs.reload()' >/dev/null 2>&1 || true
    sleep 4
  else
    note "~/.hammerspoon/init.lua already points at this checkout"
  fi
fi

# ---------------------------------------------------------------------------- bench mode
hs -c 'return require("hsc.screenshot").benchMode(true)' >/dev/null 2>&1 || \
  note "WARNING: could not enter bench mode over hs.ipc (an unreliable transport under load)"
# math.floor before tostring: hs returns Lua numbers as floats ("128.0"), and stripping
# non-digits from that yields 1280 — which is how a listings-per-shot of -230.00 got printed.
counter() { hs -c "local s=require('hsc.screenshot').stats(); return tostring(math.floor($1))" 2>/dev/null \
              | grep -a -oE '^[0-9]+$' | tail -1; }
LISTINGS_BEFORE=$(counter "(s.watcher and s.watcher.listings) or 0")
SHOTS_BEFORE=$(counter "s.counts.created or 0")

# ---------------------------------------------------------------------------- run
RECORDS="/tmp/screenshot-bench-records-$$.json"
set +e
python3 "$REPO/bench/run.py" "$N" --probe "$PROBE_BIN" --log "$LOG" --out "$RECORDS" "${EXTRA[@]+"${EXTRA[@]}"}"
RC=$?
set -e

hs -c 'return require("hsc.screenshot").benchMode(false)' >/dev/null 2>&1 || true

if [[ ! -s "$RECORDS" ]]; then
  note "no records written (rc=$RC) — nothing to analyse"
  exit "$RC"
fi

LISTINGS_AFTER=$(counter "(s.watcher and s.watcher.listings) or 0")
SHOTS_AFTER=$(counter "s.counts.created or 0")
LPS_ARG=()
if [[ -n "${LISTINGS_BEFORE:-}" && -n "${LISTINGS_AFTER:-}" && -n "${SHOTS_BEFORE:-}" && -n "${SHOTS_AFTER:-}" ]]; then
  # A reload mid-run zeroes both counters, which would print a meaningless (often negative)
  # figure; report nothing rather than a number that is not a measurement.
  LPS=$(python3 -c "
b,a,sb,sa=$LISTINGS_BEFORE,$LISTINGS_AFTER,$SHOTS_BEFORE,$SHOTS_AFTER
print(f'{(a-b)/(sa-sb):.2f}' if a>=b and sa>sb else '')" 2>/dev/null || true)
  [[ -n "$LPS" ]] && LPS_ARG=(--listings-per-shot "$LPS")
fi

MD_ARG=()
if [[ "$N" -ge 50 && "$QUICK" == "0" ]]; then
  MD_ARG=(--md "$REPO/docs/research/screenshot-acceptance-$(date +%Y-%m-%d).md")
fi

python3 "$REPO/bench/analyze.py" "$RECORDS" --log "$LOG" "${MD_ARG[@]+"${MD_ARG[@]}"}" "${LPS_ARG[@]+"${LPS_ARG[@]}"}"
ARC=$?
rm -f "$RECORDS"
exit $(( RC != 0 ? RC : ARC ))
