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
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; N="${2:-10}"; shift 2 ;;
    --no-relink) RELINK=0; shift ;;
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
trap restore_link EXIT INT TERM

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
LISTINGS_BEFORE=$(hs -c 'local s=require("hsc.screenshot").stats(); return tostring(s.watcher and s.watcher.listings or 0)' 2>/dev/null | tail -1 | tr -dc '0-9')
SHOTS_BEFORE=$(hs -c 'local s=require("hsc.screenshot").stats(); return tostring(s.counts.created or 0)' 2>/dev/null | tail -1 | tr -dc '0-9')

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

LISTINGS_AFTER=$(hs -c 'local s=require("hsc.screenshot").stats(); return tostring(s.watcher and s.watcher.listings or 0)' 2>/dev/null | tail -1 | tr -dc '0-9')
SHOTS_AFTER=$(hs -c 'local s=require("hsc.screenshot").stats(); return tostring(s.counts.created or 0)' 2>/dev/null | tail -1 | tr -dc '0-9')
LPS_ARG=()
if [[ -n "${LISTINGS_BEFORE:-}" && -n "${LISTINGS_AFTER:-}" && -n "${SHOTS_BEFORE:-}" && -n "${SHOTS_AFTER:-}" ]]; then
  LPS=$(python3 -c "
b,a,sb,sa=$LISTINGS_BEFORE,$LISTINGS_AFTER,$SHOTS_BEFORE,$SHOTS_AFTER
print(f'{(a-b)/max(1,sa-sb):.2f}')" 2>/dev/null || true)
  [[ -n "$LPS" ]] && LPS_ARG=(--listings-per-shot "$LPS")
fi

MD_ARG=()
if [[ "$N" -ge 50 && "$QUICK" == "0" ]]; then
  MD_ARG=(--md "$REPO/docs/research/screenshot-acceptance-$(date +%Y-%m-%d).md")
fi

python3 "$REPO/bench/analyze.py" "$RECORDS" "${MD_ARG[@]+"${MD_ARG[@]}"}" "${LPS_ARG[@]+"${LPS_ARG[@]}"}"
ARC=$?
rm -f "$RECORDS"
exit $(( RC != 0 ? RC : ARC ))
