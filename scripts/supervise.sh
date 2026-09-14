#!/usr/bin/env bash
# supervise.sh — launchd KeepAlive supervision of Hammerspoon, exactly one instance.
#
#   supervise.sh install     bootstrap the KeepAlive agent, assert TCC on it, THEN remove the Login
#                            Item and turn off Sparkle's auto-update (the order is the safety)
#   supervise.sh uninstall   the exact reverse: bootout, restore the Login Item and the Sparkle
#                            setting as they were before install, relaunch via LaunchServices
#                            (--no-launch: restore settings but leave Hammerspoon stopped)
#   supervise.sh status      one key=value line per fact, verdict last; exit 0 only when healthy
#   supervise.sh --prove     SIGTERM the supervised instance, print `respawn N ms` and the total
#                            detector downtime (kill → the new instance's armed heartbeat)
#
# Why (docs/research/screenshot-pipeline-2026-09-10.md §F1, §F1b, §F6; plan Phase 1):
#   - Hammerspoon was SIGTERMed by a fleet census and stayed dead for 5.4 h — nothing restarted it.
#   - On 2026-09-10 a stray second instance displaced the live one; its config never loaded, and the
#     fallback agent saw a Hammerspoon PID and deferred to the zombie. So supervision here keys on
#     the LOG HEARTBEAT (the watcher's `armed` line, written only once the config has loaded and the
#     poll is live) and never on a pid existing.
#
# 🚨 NEVER execute /Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon directly (not even with
# --version): it ignores argv and launches a second GUI instance. The launchd job and `open -a
# Hammerspoon` are the only launchers.
#
# Exit codes: 0 pass · 1 usage · 2 precondition refused · 3 respawn failed/too slow (--prove) or
# the supervised instance never came up (install) · 4 no armed heartbeat in time · 5 not exactly
# one instance · 6 TCC assertion failed (install rolled back) · 7 status: unhealthy.
set -euo pipefail

LABEL="org.hammerspoon.Hammerspoon.keepalive"
BUNDLE_ID="org.hammerspoon.Hammerspoon"
APP="/Applications/Hammerspoon.app"
DOMAIN="gui/$(id -u)"
TARGET="$DOMAIN/$LABEL"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_PLIST="$REPO_DIR/launchd/$LABEL.plist"
DST_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SHOT_LOG="$HOME/Library/Logs/Hammerspoon/screenshot.log"
STATE_DIR="$HOME/Library/Application Support/hammerspoon-config"
STATE_FILE="$STATE_DIR/supervise.state"   # pre-install Login Item + Sparkle values, for uninstall

RESPAWN_BUDGET_MS=2000   # plan target: detector downtime ≤ 2 s; the launchd re-fork alone is ~1 ms
HEARTBEAT_WAIT_S=30      # Hammerspoon start is ~0.6–2 s; a loaded box has been seen far slower
MATURE_S=11              # launchd throttles a job younger than ThrottleInterval (10 s) — §F6

say()  { printf '%s\n' "$*"; }
die()  { local rc="$1"; shift; printf 'supervise: %s\n' "$*" >&2; exit "$rc"; }

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# Every pipeline below that can legitimately match nothing ends in `|| true`: under pipefail a
# pgrep / launchctl-print miss would otherwise abort the script from inside a $(…) assignment.
hs_count() { { pgrep -x Hammerspoon || true; } | wc -l | tr -d ' '; }

job_loaded() { launchctl print "$TARGET" >/dev/null 2>&1; }

# The pid launchd holds for the job (empty when loaded-but-not-running or not loaded).
job_pid() { launchctl print "$TARGET" 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }' || true; }

# Seconds a pid has been alive, from ps's [[dd-]hh:]mm:ss etime.
pid_age_s() {
    local et; et="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')" || return 1
    [ -n "$et" ] || return 1
    local d=0 h=0 m=0 s=0
    if [[ "$et" == *-* ]]; then d="${et%%-*}"; et="${et#*-}"; fi
    IFS=: read -r -a p <<<"$et"
    case "${#p[@]}" in
        3) h="${p[0]}"; m="${p[1]}"; s="${p[2]}" ;;
        2) m="${p[0]}"; s="${p[1]}" ;;
        *) s="${p[0]}" ;;
    esac
    echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# The heartbeat: epoch-ms of the FIRST watcher-armed line at or after $1 (epoch ms), else nothing.
# Accepts both the legacy line (`2026-09-13 18:24:43.245 I screenshot poll armed on …`) and the
# logfmt line W1 introduces (`ts=2026-09-13T18:24:43.245-0500 mono=… phase=armed …`); both are
# local wall-clock time with ms, the same clock now_ms() reads.
armed_since_ms() {
    [ -r "$SHOT_LOG" ] || return 0
    perl -MPOSIX=mktime -ne '
        BEGIN { $since = shift @ARGV }
        next unless /poll armed|\bphase=armed\b/;
        next unless /^(?:ts=)?(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)(?:\.(\d{1,3}))?/;
        my $ms = mktime($6, $5, $4, $3, $2 - 1, $1 - 1900, 0, 0, -1) * 1000 + ($7 // 0);
        if ($ms >= $since) { print "$ms\n"; exit 0 }
    ' "$1" "$SHOT_LOG"
}

# Block until an armed line at/after $1 appears; print its epoch ms. rc 1 on timeout.
wait_armed() {
    local since="$1" deadline=$(( $(date +%s) + HEARTBEAT_WAIT_S )) ms
    while [ "$(date +%s)" -lt "$deadline" ]; do
        ms="$(armed_since_ms "$since")"
        if [ -n "$ms" ]; then echo "$ms"; return 0; fi
        sleep 0.05
    done
    return 1
}

# Block until launchd reports a running pid different from $1; print it. rc 1 on timeout.
wait_job_pid() {
    local old="${1:-0}" deadline=$(( $(date +%s) + HEARTBEAT_WAIT_S )) pid
    while [ "$(date +%s)" -lt "$deadline" ]; do
        pid="$(job_pid)"
        if [ -n "$pid" ] && [ "$pid" != "$old" ]; then echo "$pid"; return 0; fi
        sleep 0.05
    done
    return 1
}

wait_no_hammerspoon() {
    local deadline=$(( $(date +%s) + ${1:-10} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ "$(hs_count)" = 0 ] && return 0
        sleep 0.1
    done
    return 1
}

# Ask the running instance over hs.ipc, with retries: a freshly started instance's IPC port can
# lag the armed line, and the transport drops replies under load (KB §2) — an empty reply is "no
# answer yet", never "false".
hs_eval() {
    local out
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        out="$(timeout 5 hs -c "$1" 2>/dev/null || true)"
        if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
        sleep 0.5
    done
    return 1
}

login_item_count() {
    osascript -e "tell application \"System Events\" to count (every login item whose name is \"Hammerspoon\")" 2>/dev/null || echo "?"
}

sparkle_auto_update() { defaults read "$BUNDLE_ID" SUAutomaticallyUpdate 2>/dev/null || echo unset; }

# ---------------------------------------------------------------------------------------------
cmd_status() {
    local healthy=1 pid n age armed start_ms li su
    if job_loaded; then say "job=loaded"; else say "job=absent"; healthy=0; fi
    if [ -f "$DST_PLIST" ]; then
        if cmp -s "$SRC_PLIST" "$DST_PLIST"; then say "plist=current"; else say "plist=DRIFTED (installed ≠ repo; re-run install)"; healthy=0; fi
    else
        say "plist=absent"; healthy=0
    fi
    pid="$(job_pid)"; n="$(hs_count)"
    say "job_pid=${pid:-none} instances=$n"
    [ -n "$pid" ] || healthy=0
    [ "$n" = 1 ] || healthy=0
    if [ -n "$pid" ] && [ "$n" = 1 ] && [ "$(pgrep -x Hammerspoon)" != "$pid" ]; then
        say "instance=NOT-THE-JOB (the one running Hammerspoon is not launchd's)"; healthy=0
    fi
    # launchd's own counters: a climbing `runs` with a young age_s is a crash loop (the default
    # ThrottleInterval relaunches a start-up crash every 10 s, forever — plan § Completeness critic 2).
    launchctl print "$TARGET" 2>/dev/null | awk -F' = ' '$1 ~ /^\t(runs|last exit code|last terminating signal)$/ {
        k = $1; sub(/^\t/, "", k); gsub(/ /, "_", k); print "launchd_" k "=" $2 }' || true
    if [ -n "$pid" ] && age="$(pid_age_s "$pid")"; then
        say "age_s=$age"
        start_ms=$(( ( $(date +%s) - age - 1 ) * 1000 ))
        armed="$(armed_since_ms "$start_ms")"
        if [ -n "$armed" ]; then
            say "heartbeat=armed $(( ( $(now_ms) - armed ) / 1000 ))s ago (after this instance started)"
        else
            say "heartbeat=MISSING — this instance never armed the watcher (config not loaded?)"; healthy=0
        fi
    fi
    li="$(login_item_count)"; su="$(sparkle_auto_update)"
    say "login_item=$li sparkle_auto_update=$su"
    [ "$li" = 0 ] || healthy=0
    [ "$su" = 0 ] || healthy=0
    if [ "$healthy" = 1 ]; then say "verdict=supervised"; return 0; fi
    say "verdict=NOT-HEALTHY"; return 7
}

# ---------------------------------------------------------------------------------------------
record_state_once() {
    [ -f "$STATE_FILE" ] && return 0     # a re-run must not overwrite the ORIGINAL pre-install values
    mkdir -p "$STATE_DIR"
    local hidden="absent"
    if [ "$(login_item_count)" != 0 ]; then
        hidden="$(osascript -e 'tell application "System Events" to get hidden of first login item whose name is "Hammerspoon"' 2>/dev/null || echo false)"
    fi
    printf 'login_item=%s\nsparkle_auto_update=%s\n' "$hidden" "$(sparkle_auto_update)" >"$STATE_FILE"
}

state_get() { if [ -f "$STATE_FILE" ]; then awk -F= -v k="$1" '$1 == k { print $2 }' "$STATE_FILE"; fi; }

rollback_install() {
    say "  ROLLBACK: booting the agent out and relaunching Hammerspoon the old way."
    launchctl bootout "$TARGET" 2>/dev/null || true
    rm -f "$DST_PLIST"
    wait_no_hammerspoon 10 || true
    open -a Hammerspoon || true
}

cmd_install() {
    [ -x "$APP/Contents/MacOS/Hammerspoon" ] || die 2 "$APP is not installed"
    plutil -lint "$SRC_PLIST" >/dev/null || die 2 "$SRC_PLIST does not lint"

    if job_loaded && cmp -s "$SRC_PLIST" "$DST_PLIST"; then
        say "  Agent already bootstrapped from the current plist — not restarting Hammerspoon."
    else
        local n; n="$(hs_count)"
        [ "$n" -le 1 ] || die 5 "$n Hammerspoon processes are running ($(pgrep -x Hammerspoon | tr '\n' ' ')) — refusing to add a supervisor on top of a double launch; quit the extra one first"
        record_state_once
        if job_loaded; then
            say "  Installed plist differs from the repo — replacing the agent."
            launchctl bootout "$TARGET"
        elif [ "$n" = 1 ]; then
            # Bootstrapping with RunAtLoad beside a LaunchServices instance is exactly the 2026-09-10
            # double launch (KB §F1b), so the unsupervised instance goes first. SIGTERM is also what
            # launchd itself sends a job on bootout.
            say "  Stopping the unsupervised Hammerspoon (pid $(pgrep -x Hammerspoon))..."
            pkill -TERM -x Hammerspoon || true
        fi
        wait_no_hammerspoon 10 || die 2 "Hammerspoon did not exit within 10 s — not bootstrapping beside it"

        mkdir -p "$(dirname "$DST_PLIST")"
        install -m 0644 "$SRC_PLIST" "$DST_PLIST"
        local t0 pid armed
        t0="$(now_ms)"
        launchctl bootstrap "$DOMAIN" "$DST_PLIST"
        if ! pid="$(wait_job_pid 0)"; then rollback_install; die 3 "launchd never reported a running pid"; fi
        say "  launchd started Hammerspoon: pid $pid"
        if ! armed="$(wait_armed "$t0")"; then
            rollback_install; die 4 "no armed heartbeat within ${HEARTBEAT_WAIT_S}s — the config did not load under launchd"
        fi
        say "  Watcher armed $(( armed - t0 )) ms after bootstrap."
    fi

    # 🚨 TCC BEFORE the Login Item goes (plan § Completeness critic item 1): launch provenance
    # decides which grants apply, and this provenance had never been exercised. If the launchd
    # instance lacks Accessibility the ⌘V→⌃V tap is dead — so assert it while the old launcher
    # still exists, and roll back rather than delete it.
    local tcc
    tcc="$(hs_eval 'return tostring(hs.accessibilityState())..","..tostring(hs.screenRecordingState())..","..tostring(hs.eventtap and true)')" \
        || { rollback_install; die 6 "could not ask the supervised instance for its TCC state over hs.ipc"; }
    say "  TCC accessibility,screen-recording,eventtap = $tcc"
    [ "$tcc" = "true,true,true" ] || { rollback_install; die 6 "supervised instance is missing a grant ($tcc)"; }

    if [ "$(login_item_count)" != 0 ]; then
        osascript -e 'tell application "System Events" to delete (every login item whose name is "Hammerspoon")' >/dev/null
    fi
    [ "$(login_item_count)" = 0 ] || die 2 "the Hammerspoon Login Item is still present after delete"
    say "  Login Item removed (launchd is now the only launcher)."

    defaults write "$BUNDLE_ID" SUAutomaticallyUpdate -bool false
    say "  Sparkle auto-update off (updates stay manual from the Hammerspoon menu)."

    local n; n="$(hs_count)"
    [ "$n" = 1 ] || die 5 "expected exactly one Hammerspoon after install, found $n"
    [ "$(pgrep -x Hammerspoon)" = "$(job_pid)" ] || die 5 "the running Hammerspoon is not launchd's job"
    say "  Supervised: one instance, pid $(job_pid)."
}

# ---------------------------------------------------------------------------------------------
cmd_uninstall() {
    local launch=1
    [ "${1:-}" = "--no-launch" ] && launch=0

    if job_loaded; then
        launchctl bootout "$TARGET"
        say "  Agent booted out."
    fi
    rm -f "$DST_PLIST"
    wait_no_hammerspoon 10 || say "  WARNING: a Hammerspoon process is still running after bootout."

    local su; su="$(state_get sparkle_auto_update)"; su="${su:-1}"
    if [ "$su" = unset ]; then
        defaults delete "$BUNDLE_ID" SUAutomaticallyUpdate 2>/dev/null || true
    else
        defaults write "$BUNDLE_ID" SUAutomaticallyUpdate -bool "$([ "$su" = 1 ] && echo true || echo false)"
    fi
    say "  Sparkle auto-update restored ($su)."

    local li; li="$(state_get login_item)"; li="${li:-false}"   # no record ⇒ the documented default: a visible Login Item
    if [ "$li" != absent ] && [ "$(login_item_count)" = 0 ]; then
        osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP\", hidden:$li}" >/dev/null
        say "  Login Item restored (hidden:$li)."
    fi
    rm -f "$STATE_FILE"

    if [ "$launch" = 1 ]; then
        local t0; t0="$(now_ms)"
        open -a Hammerspoon
        if wait_armed "$t0" >/dev/null; then say "  Hammerspoon relaunched unsupervised; watcher armed."
        else say "  WARNING: relaunched, but no armed heartbeat within ${HEARTBEAT_WAIT_S}s."; fi
    fi
}

# ---------------------------------------------------------------------------------------------
cmd_prove() {
    job_loaded || die 2 "the agent is not bootstrapped — run: bash $0 install"
    local old n age
    old="$(job_pid)"; n="$(hs_count)"
    [ -n "$old" ] || die 2 "the job is loaded but not running"
    [ "$n" = 1 ] || die 5 "expected exactly one Hammerspoon before the kill, found $n"
    [ "$(pgrep -x Hammerspoon)" = "$old" ] || die 5 "the running Hammerspoon is not launchd's job"
    age="$(pid_age_s "$old")" || die 2 "cannot read the age of pid $old"
    # A job younger than ThrottleInterval is held back ~10 s by launchd; that measures the throttle,
    # not supervision (KB §F6 row 1), so wait it out instead of reporting a false failure.
    if [ "$age" -lt "$MATURE_S" ]; then
        say "job is ${age}s old; waiting $(( MATURE_S - age ))s so launchd will not throttle the respawn"
        sleep $(( MATURE_S - age ))
    fi
    say "pid $old — launchctl kill TERM $TARGET"

    # One process for kill + poll so the timing is not padded by process spawns between them.
    local out t0 new respawn armed
    out="$(perl -MTime::HiRes=time,sleep -e '
        my ($target, $old) = @ARGV;
        my $t0 = time;
        system("launchctl", "kill", "TERM", $target) == 0 or exit 9;
        while (time - $t0 < 15) {
            my $p = `launchctl print $target 2>/dev/null`;
            if ($p =~ /^\s*pid = (\d+)/m && $1 != $old) {
                printf "%d %d %d\n", $t0 * 1000, $1, (time - $t0) * 1000; exit 0;
            }
            sleep 0.002;
        }
        printf "%d 0 -1\n", $t0 * 1000; exit 1;
    ' "$TARGET" "$old")" || true
    read -r t0 new respawn <<<"$out"
    [ -n "${respawn:-}" ] || die 3 "launchctl kill failed"
    if [ "$respawn" -lt 0 ]; then die 3 "no new pid within 15 s of the kill"; fi
    say "respawn $respawn ms (pid $old → $new)"

    if ! armed="$(wait_armed "$t0")"; then die 4 "no armed heartbeat within ${HEARTBEAT_WAIT_S}s of the kill"; fi
    say "detector downtime $(( armed - t0 )) ms (kill → watcher armed)"

    n="$(hs_count)"
    say "instances $n"
    [ "$n" = 1 ] || die 5 "expected exactly one Hammerspoon after the respawn, found $n"
    [ "$respawn" -lt "$RESPAWN_BUDGET_MS" ] || die 3 "respawn $respawn ms is over the ${RESPAWN_BUDGET_MS} ms budget"
    say "PASS"
}

case "${1:-}" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall "${2:-}" ;;
    status)    cmd_status ;;
    --prove)   cmd_prove ;;
    *) printf 'usage: %s {install|uninstall [--no-launch]|status|--prove}\n' "$0" >&2; exit 1 ;;
esac
