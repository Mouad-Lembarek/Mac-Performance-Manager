#!/bin/bash
# Lightweight test suite for mac-performance-manager.sh.
#
#   ./tests/run_tests.sh                    # uses /bin/bash (3.2 on macOS)
#   MPM_TEST_SHELL=/path/to/bash ./tests/run_tests.sh
#
# macOS tools are replaced by stubs in tests/bin that print fixture output from
# tests/fixtures, so results do not depend on the state of the machine. Safety tests
# use real, throw-away processes owned by you (a symlink to sleep inside the temporary
# folder; macOS kills *copies* of its own signed binaries). Faults such as "another
# user's process" or "PID reused" are injected by the ps stub for those test processes
# only. Nothing outside a temporary folder is touched; only processes started by this
# script are ever signalled, and only after their identity is re-checked.

# Variables below are read inside eval'd check expressions, which shellcheck cannot see.
# shellcheck disable=SC2034,SC2010
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/mac-performance-manager.sh"
SH=${MPM_TEST_SHELL:-/bin/bash}
STUBS="$HERE/bin"
export MPM_FIX="$HERE/fixtures"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mpm-tests.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
export MPM_FAKE_STATE="$TMP/fake"; mkdir -p "$MPM_FAKE_STATE"
export HOME="$TMP/home"; mkdir -p "$HOME/.Trash"
# Git must not read the user's or the system's configuration (global ignores, hooks...).
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset MPM_CONFIG NO_COLOR XDG_CONFIG_HOME MPM_REAL_PS MPM_FAKE_PS_PID MPM_FAKE_PS_MODE MPM_FAKE_OS MPM_FAKE_NO_PRESSURE
PASS=0; FAIL=0; SKIP=0
CHILDREN=""

# Kill only processes this script started, and only while they still are those processes
# (a PID that exited early may have been reused by something else).
cleanup() {
  local p
  for p in $CHILDREN; do
    case $(/bin/ps -o args= -p "$p" 2>/dev/null) in *"$TMP"*|*"$SCRIPT"*) kill -KILL "$p" 2>/dev/null ;; esac
  done
  case $TMP in */mpm-tests.*) rm -rf -- "$TMP" ;; esac
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | head -n 15 | sed 's/^/        | /'; }
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s (%s)\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }
contains() { case $1 in *"$2"*) return 0 ;; esac; return 1; }

CFG="$TMP/test.env"
printf 'DATA_DIR=%s/data\nNOTIFICATIONS_ENABLED=false\nCOLOR=never\n' "$TMP" > "$CFG"

mpm() { PATH="$STUBS:$PATH" "$SH" "$SCRIPT" --config "$CFG" "$@"; }
# Run a snippet with the script's functions loaded (main() is not executed).
src() {
  PATH="$STUBS:$PATH" MPM_SOURCE_ONLY=1 "$SH" -c ". '$SCRIPT'; set_defaults; COLOR=never; DATA_DIR='$TMP/data'; detect_platform; init_dirs; setup_colors; $1" 2>&1
}

echo "Shell under test: $SH ($("$SH" -c 'echo $BASH_VERSION'))"
echo "awk: $(command -v awk)   platform: $(uname -s)"

# ---------------------------------------------------------------------------
echo "[static]"
check "syntax (bash -n)" '"$SH" -n "$SCRIPT"'
out=$(grep -nE '(^|[;&|[:space:]])(sudo|killall|pkill)[[:space:]]' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE "echo|printf|T_REASON|note |\"[^\"]*(sudo|killall|pkill)")
check "no sudo / killall / pkill invocations" '[ -z "$out" ]' "$out"
out=$(grep -nE '(^|[;&|[:space:]])purge([[:space:]]|$)' "$SCRIPT" | grep -vE 'echo|printf|#|"[^"]*purge|cache purge')
check "no 'purge' command invocations" '[ -z "$out" ]' "$out"
out=$(grep -n 'rm -rf' "$SCRIPT" | grep -v 'printf')
check "rm -rf only appears as advice text, never executed" '[ -z "$out" ]' "$out"
out=$(grep -n 'kill -KILL\|kill -9' "$SCRIPT" | grep -v '^\s*#')
n=$(printf '%s\n' "$out" | grep -c 'kill -KILL "$pid"')
check "SIGKILL only in the confirmed terminate flow" '[ "$n" = 1 ] && [ "$(printf "%s\n" "$out" | grep -c .)" = 1 ]' "$out"
out=$(awk '/^[a-z_]+\(\) *\{/ { f = $1 } /kill -TERM "\$2"/ { print f }' "$SCRIPT")
check "the only automatic signal is SIGTERM inside auto_terminate" '[ "$out" = "auto_terminate()" ]' "$out"
out=$(grep -nE 'memory_pressure[[:space:]]+-' "$SCRIPT")
check "memory_pressure never called with simulation flags" '[ -z "$out" ]' "$out"
out=$(grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}|\|&|&>>|local -n|EPOCHSECONDS|printf .%\(' "$SCRIPT")
check "no bash 4+ only constructs" '[ -z "$out" ]' "$out"
out=$(grep -nE 'sed -i|grep -P|sort -h|readlink -f|stat -c|numfmt|gensub|strftime|asort' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#')
check "no GNU-only utilities/options" '[ -z "$out" ]' "$out"
out=$(grep -nE 'curl|wget|nc |https?://' "$SCRIPT")
check "no network access" '[ -z "$out" ]' "$out"
out=$(grep -nE '(echo|printf).*[^0-9.][0-9]+ GB' "$SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*#')
check "no hard-coded RAM size in user-facing text" '[ -z "$out" ]' "$out"
out=$(grep -n 'rm -rf' "$SCRIPT" | grep -v 'shell_quote')
check "printed rm -rf hint quotes its path with shell_quote" '[ -z "$out" ]' "$out"
out=$(grep -nE 'no automatic kills|Nothing is ever stopped, quit or deleted automatically' "$SCRIPT" "$ROOT"/*.md "$ROOT"/docs/*.md)
check "no unconditional 'never automatic' claims (opt-in auto-stop exists)" '[ -z "$out" ]' "$out"
check "header, help, README and guide all disclose the opt-in auto-stop" 'grep -q "AUTO_STOP_IDLE_\*" "$SCRIPT" && grep -q "Sole exception, OFF by default" "$SCRIPT" && grep -q "AUTO_STOP_IDLE_\*" "$ROOT/README.md" && grep -q "AUTO_STOP_IDLE_TSSERVER" "$ROOT/docs/GUIDE.md"'
# Relative links in the docs point to files that exist (anchors are not checked).
out=$(for f in "$ROOT"/*.md "$ROOT"/docs/*.md; do
  grep -oE '\]\([^)#:]+(#[^)]*)?\)' "$f" | sed -E 's/^\]\(//; s/[#)].*$//' | while IFS= read -r l; do
    [ -e "$(dirname "$f")/$l" ] || echo "${f#"$ROOT"/}: $l"; done; done)
check "documentation links point to existing files" '[ -z "$out" ]' "$out"

# ---------------------------------------------------------------------------
echo "[cli]"
out=$("$SH" "$SCRIPT" --help 2>&1); rc=$?
check "--help works without macOS tools" '[ $rc = 0 ] && contains "$out" "Usage:" && contains "$out" "--work" && contains "$out" "--report"'
check "--help discloses the opt-in automatic stops" 'contains "$out" "opt-in AUTO_STOP_IDLE_*" && contains "$out" "off by default" && ! contains "$out" "no automatic kills"' "$out"
out=$("$SH" "$SCRIPT" --version 2>&1)
check "--version" 'contains "$out" "mac-performance-manager 1."'
out=$("$SH" "$SCRIPT" --bogus 2>&1); rc=$?
check "unknown option exits 2" '[ $rc = 2 ] && contains "$out" "unknown option"'
out=$(PATH="$STUBS:$PATH" MPM_FAKE_OS=Linux "$SH" "$SCRIPT" --once --config "$CFG" 2>&1); rc=$?
check "refuses to run on non-macOS" '[ $rc = 1 ] && contains "$out" "macOS only"' "$out"

# ---------------------------------------------------------------------------
echo "[config]"
out=$("$SH" "$SCRIPT" --check-config --config "$MPM_FIX/config_valid.env" 2>&1); rc=$?
check "--check-config exits 0 for a valid config" '[ $rc = 0 ]' "rc=$rc"
check "valid config values applied" 'printf "%s\n" "$out" | grep -q "LIVE_INTERVAL_SEC *5$" && printf "%s\n" "$out" | grep -q "WORK_INTERVAL_SEC *15$" && printf "%s\n" "$out" | grep -q "SUSTAINED_SAMPLES *2$" && printf "%s\n" "$out" | grep -q "DISK_FREE_WARN_GB *30$" && printf "%s\n" "$out" | grep -q "LOGGING_ENABLED *false$"' "$out"
check "valid config has no warnings" '! contains "$out" "Warnings:"' "$out"
out=$("$SH" "$SCRIPT" --check-config --config "$TMP/does-not-exist.env" 2>&1); rc=$?
check "missing config -> warning + defaults" 'contains "$out" "not found" && printf "%s\n" "$out" | grep -q "LIVE_INTERVAL_SEC *4$"' "$out"
check "--check-config exits 1 when the given config file is missing" '[ $rc = 1 ]' "rc=$rc"
# A copy in an empty folder: the user's own config.env next to the real script must not matter.
mkdir -p "$TMP/noconf"; cp "$SCRIPT" "$TMP/noconf/mpm.sh"
out=$(cd "$TMP" && "$SH" "$TMP/noconf/mpm.sh" --check-config 2>&1); rc=$?
check "no config.env at all -> silent defaults" 'contains "$out" "using defaults" && ! contains "$out" "Warnings:"' "$out"
check "--check-config exits 0 with no config.env (defaults are valid)" '[ $rc = 0 ]' "rc=$rc"
rm -f /tmp/mpm_pwned_test
out=$("$SH" "$SCRIPT" --check-config --config "$MPM_FIX/config_invalid.env" 2>&1); rc=$?
check "--check-config exits 1 when the config has errors (still prints everything)" '[ $rc = 1 ] && contains "$out" "Warnings:" && printf "%s\n" "$out" | grep -q "LIVE_INTERVAL_SEC *4$"' "rc=$rc"
check "config is parsed, never executed" '[ ! -e /tmp/mpm_pwned_test ]'
check "invalid integer rejected, default kept" 'contains "$out" "LIVE_INTERVAL_SEC=" && printf "%s\n" "$out" | grep -q "LIVE_INTERVAL_SEC *4$" && printf "%s\n" "$out" | grep -q "WORK_INTERVAL_SEC *30$"' "$out"
check "out-of-range, bad bool, bad enum, unknown key, garbage line all reported" 'contains "$out" "SUSTAINED_SAMPLES=" && contains "$out" "LOGGING_ENABLED=" && contains "$out" "COLOR=" && contains "$out" "unknown setting" && contains "$out" "expected KEY=VALUE" && contains "$out" "absolute path"' "$out"
check "inconsistent pressure thresholds reset to 20/10" 'printf "%s\n" "$out" | grep -q "PRESSURE_WARN_FREE_PCT *20$" && printf "%s\n" "$out" | grep -q "PRESSURE_CRIT_FREE_PCT *10$"' "$out"
printf 'WORK_INTERVAL_SEC=30\nWORK_RELAXED_INTERVAL_SEC=10\nWORK_RELAX_AFTER_SAMPLES=0\nDEV_CANDIDATE_MIN_MB=0\nSESSION_REPORT_ENABLED=maybe\n' > "$TMP/ws.env"
out=$("$SH" "$SCRIPT" --check-config --config "$TMP/ws.env" 2>&1)
check "work-session settings validated (relaxed >= normal, 0 = never relax, ranges, booleans)" 'printf "%s\n" "$out" | grep -q "WORK_RELAXED_INTERVAL_SEC *30$" && printf "%s\n" "$out" | grep -q "WORK_RELAX_AFTER_SAMPLES *0$" && contains "$out" "DEV_CANDIDATE_MIN_MB=" && contains "$out" "SESSION_REPORT_ENABLED=" && contains "$out" "must not be lower than WORK_INTERVAL_SEC"' "$out"

# ---------------------------------------------------------------------------
echo "[parsers]"
out=$(src 'parse_vm_stat < "$MPM_FIX/vm_stat.txt"')
check "vm_stat parsing" '[ "$out" = "16384 10240 120000 115000 1500 0 95000 2000 40000 196500 400000 130000 12345678 23456 3456789 4567890" ]' "$out"
out=$(src 'collect_memory; echo "$MEM_APP_MB $MEM_WIRED_MB $MEM_COMP_MB $MEM_STORED_MB $MEM_CACHED_MB $MEM_USED_MB $COMP_RATIO_X10"')
check "memory metrics derived from vm_stat" '[ "$out" = "3039 1484 2031 6250 656 6554 30" ]' "$out"
out=$(src 'parse_swapusage < "$MPM_FIX/swapusage.txt"; echo "total = 2.00G  used = 1.50G  free = 512.00M  (encrypted)" | parse_swapusage; echo "total = 0.00M  used = 0.00M  free = 0.00M" | parse_swapusage')
check "swap parsing (M, G units, zero swap)" '[ "$out" = "14336 13504 832
2048 1536 512
0 0 0" ]' "$out"
out=$(src 'parse_df < "$MPM_FIX/df.txt"')
check "df parsing" '[ "$out" = "239362496 180000000 43200000" ]' "$out"
out=$(src 'parse_pmset_batt < "$MPM_FIX/pmset.txt"; printf "Now drawing from %s\n" "'"'"'AC Power'"'"'" | parse_pmset_batt')
check "pmset parsing (laptop and desktop Mac)" '[ "$out" = "AC power|78|charging
AC power|-|-" ]' "$out"
out=$(src 'parse_top < "$MPM_FIX/top.txt"')
check "top parsing uses 2nd sample only" 'contains "$out" "C 21.50 8.50 70.00" && ! contains "$out" "C 50.00"' "$out"
check "top memory units (G, M, K, B, N/A)" 'contains "$out" "T 1004 92.1 1153433" && contains "$out" "T 1001 12.0 839680" && contains "$out" "T 42 0.0 512" && contains "$out" "T 0 10.2 0" && contains "$out" "T 150 4.0 -1"' "$out"
out=$(src 'parse_memory_pressure_free < "$MPM_FIX/memory_pressure.txt"')
check "memory_pressure free% parsing" '[ "$out" = 18 ]' "$out"

out=$(src 'collect_procs precise; printf "%s\n" "$PROCS"')
row() { printf '%s\n' "$out" | awk -F'\t' -v p="$1" '$1 == p { print $7 "|" $8 "|" $9 "|" $10 "|" $11 "|" $12 }'; }
check "classify Cursor renderer (footprint)" '[ "$(row 1001)" = "F|Cursor|Cursor|Cursor Helper (Renderer)|-|renderer" ]' "$(row 1001)"
check "classify Cursor plugin helper" '[ "$(row 1004)" = "F|Cursor|Cursor|Cursor Helper (Plugin)|-|plugin" ]' "$(row 1004)"
check "classify bundled tool inside Cursor.app" '[ "$(row 1007)" = "R|Cursor|Cursor|rg|-|tool" ]' "$(row 1007)"
check "Node.js started by Cursor (via extension host)" '[ "$(row 1100)" = "F|Node.js|Node.js|node|Cursor|-" ]' "$(row 1100)"
check "Node.js dev server in Cursor terminal" '[ "$(row 1102)" = "R|Node.js|Node.js|node|Cursor|-" ]' "$(row 1102)"
check "Brave helper grouped under Brave" '[ "$(row 1201)" = "F|Brave|Brave|Brave Browser Helper (Renderer)|-|renderer" ]' "$(row 1201)"
check "framework Python and venv python3" '[ "$(row 1500)" = "R|Python|Python|Python|Terminal|main" ] && [ "$(row 1501)" = "R|Python|Python|python3|Terminal|-" ]' "$(row 1500) / $(row 1501)"
check "Docker backend, VM, local AI, system" '[ "$(row 1601)" = "R|Docker|Docker|com.docker.backend|-|tool" ] && [ "$(row 1600)" = "F|Virtual machine|VM|com.apple.Virtualization.VirtualMachine|-|-" ] && [ "$(row 1700)" = "R|ollama|Local AI|ollama|-|-" ] && [ "$(row 150)" = "R|WindowServer|System|WindowServer|-|-" ]' "$(row 1601) $(row 1600) $(row 1700) $(row 150)"
# Processes Cursor starts that rename themselves (extension hosts) or are unclassified (tsserver)
# count toward Cursor; runtimes keep their group, and other apps' children are not reassigned.
{ cat "$MPM_FIX/ps.txt"
  printf ' 1010  1004 @UID@  400000   0.2 Cursor Helper (Plugin): extension-host (user) proj [1-1]\n'
  printf ' 1011  1004 @UID@  300000   0.0 tsserver[6.0.3]: semantic\n'
  printf ' 1012  1499 @UID@  200000   0.5 claude\n'; } > "$MPM_FAKE_STATE/ps.txt"
out=$(src 'collect_procs fast; printf "%s\n" "$PROCS"; echo "SUM $SUM_CUR_N $SUM_CUR_PLUG"')
rm -f "$MPM_FAKE_STATE/ps.txt"
check "renamed Cursor extension host grouped under Cursor (plugin)" '[ "$(row 1010)" = "R|Cursor|Cursor|Cursor Helper (Plugin): extension-host (user) proj [1-1]|Cursor|plugin" ]' "$(row 1010)"
check "tsserver started by Cursor grouped under Cursor" '[ "$(row 1011)" = "R|Cursor|Cursor|tsserver[6.0.3]: semantic|Cursor|tool" ]' "$(row 1011)"
check "Node.js started by Cursor keeps its own group" '[ "$(row 1100 | cut -d"|" -f2-3)" = "Node.js|Node.js" ]' "$(row 1100)"
check "a process started by Terminal is not reassigned to Terminal" '[ "$(row 1012)" = "R|claude|Other|claude|Terminal|-" ]' "$(row 1012)"
check "Cursor totals include them (10 processes, 3 plugin hosts)" 'contains "$out" "SUM 10 3"' "$(printf '%s\n' "$out" | tail -n 1)"
out=$(src 'collect_procs fast; echo "$PROC_MEM_SRC $SUM_CUR_N $SUM_CUR_REND $SUM_CUR_PLUG $SUM_NODE_N $SUM_PY_N $SUM_BRAVE_N"')
check "fast mode uses RSS and counts groups" '[ "$out" = "RSS 8 2 2 2 2 3" ]' "$out"

out=$(MPM_FAKE_NO_PRESSURE=1 src 'collect_memory; collect_pressure; echo "$PRESS_LEVEL|$FREE_PCT|$PRESS_SOURCE"')
check "pressure falls back to read-only memory_pressure" '[ "$out" = "|18|memory_pressure" ] && [ ! -e "$MPM_FAKE_STATE/forbidden" ]' "$out"

out=$(src 'printf "%s\n" "node app.js --token abc123 --api-key XYZ OPENAI_API_KEY=sk-1234567890abcdefghijklmnopqrstuv psql postgres://bob:pw@h/db --useInferredProjectPerProjectRoot" | redact_args')
check "secret redaction (display only)" '! contains "$out" "abc123" && ! contains "$out" "XYZ" && ! contains "$out" "sk-123" && ! contains "$out" "bob:pw" && contains "$out" "--useInferredProjectPerProjectRoot" && contains "$out" "node app.js"' "$out"

# ---------------------------------------------------------------------------
echo "[analysis]"
out=$(src 'SUSTAINED_SAMPLES=3; MEM_TOTAL_MB=8192; SWAP_TREND=stable
  PRESS_LEVEL=2; FREE_PCT=18; SWAPOUT_RATE=0
  evaluate_state; a=$VERDICT; evaluate_state; b=$VERDICT; evaluate_state; c=$VERDICT
  PRESS_LEVEL=1; FREE_PCT=45; evaluate_state; d=$VERDICT
  PRESS_LEVEL=4; FREE_PCT=5; evaluate_state; evaluate_state; evaluate_state; e=$VERDICT
  echo "$a $b $c $d $e"')
check "sustained logic: WATCH,WATCH,HIGH; recovers; CRITICAL" '[ "$out" = "WATCH WATCH HIGH OK CRITICAL" ]' "$out"
out=$(src 'SUSTAINED_SAMPLES=3; SWAP_TREND=stable; PRESS_LEVEL=1; FREE_PCT=50; SWAP_OK=1; SWAP_USED_MB=13000; SWAPOUT_RATE=0
  evaluate_state; evaluate_state; evaluate_state; echo "$VERDICT"')
check "large existing swap alone is not a problem" '[ "$out" = OK ]' "$out"
out=$(src 'SUSTAINED_SAMPLES=2; SWAP_TREND=stable; PRESS_LEVEL=1; FREE_PCT=50; SWAPOUT_RATE=400
  evaluate_state; a=$VERDICT; evaluate_state; echo "$a $VERDICT"')
check "sustained active swap-out escalates" '[ "$out" = "WATCH HIGH" ]' "$out"
out=$(src 'SUSTAINED_SAMPLES=3; PRESS_LEVEL=""; FREE_PCT=""; evaluate_state; echo "$VERDICT"')
check "unreadable pressure -> UNKNOWN, not a guess" '[ "$out" = UNKNOWN ]' "$out"
out=$(src 'SWAP_OK=1; SWAP_TREND_WINDOW_MIN=30; SWAP_GROWTH_WARN_MB=1024; now=$(date +%s)
  SWAP_HIST=$(printf "%s\t%s" $((now - 1500)) 10000); SWAP_USED_MB=12000; update_swap_trend $now; a=$SWAP_TREND
  SWAP_HIST=$(printf "%s\t%s" $((now - 1500)) 11800); SWAP_USED_MB=12000; update_swap_trend $now; b=$SWAP_TREND
  SWAP_HIST=$(printf "%s\t%s" $((now - 120)) 9000); SWAP_USED_MB=12000; update_swap_trend $now; c=$SWAP_TREND
  SWAP_HIST=$(printf "%s\t%s" $((now - 1500)) 14000); SWAP_USED_MB=12000; update_swap_trend $now; d=$SWAP_TREND
  echo "$a $b $c $d"')
check "swap trend: growing / stable / collecting / shrinking" '[ "$out" = "growing stable collecting shrinking" ]' "$out"
out=$(src 'HISTORY_MAX_LINES=100; i=0; while [ $i -lt 150 ]; do echo "$i	1"; i=$((i+1)); done > "$HISTORY_FILE"; trim_history; wc -l < "$HISTORY_FILE" | tr -d " "; tail -n 1 "$HISTORY_FILE" | cut -f1')
check "history trimmed to HISTORY_MAX_LINES (keeps newest)" '[ "$out" = "100
149" ]' "$out"
out=$(src 'LOGGING_ENABLED=true; LOG_MAX_KB=16; i=0; while [ $i -lt 400 ]; do log_event INFO "line $i padding padding padding"; i=$((i+1)); done; ls "$LOG_DIR"; [ $(wc -c < "$EVENT_LOG") -le 17000 ] && echo SIZE_OK')
check "event log rotates at LOG_MAX_KB" 'contains "$out" "events.log.1" && contains "$out" "SIZE_OK"' "$out"
t0=$(date +%s)
# Recommendations adapt to the detected RAM (H1/H2). Fixture groups: Cursor ~3 GB, Brave ~1 GB, ...
reco() { src "init_monitor_state; collect_procs precise; $1; build_recommendations"; }
out8=$(reco 'MEM_TOTAL_MB=8192; VERDICT=HIGH')
out128=$(reco 'MEM_TOTAL_MB=131072; VERDICT=HIGH')
check "8 GB Mac: groups above 10% of RAM are named (unchanged)" 'contains "$out8" "* Cursor:"' "$out8"
check "128 GB Mac under pressure: cutoff capped at 1 GB, consumers still named" 'contains "$out128" "* Cursor:" && [ "$(printf "%s\n" "$out128" | grep -c "^  \* ")" -ge 1 ]' "$out128"
check "large RAM: only groups of 1 GB or more pass the capped cutoff" '[ "$(printf "%s\n" "$out128" | grep -c "^  \* ")" -le "$(printf "%s\n" "$out8" | grep -c "^  \* ")" ]' "8GB: $out8 / 128GB: $out128"
out=$(reco 'MEM_TOTAL_MB=8192; APP_HEAVY_PCT=100; APP_HEAVY_CAP_MB=999999; VERDICT=WATCH')
check "no group reaches the cutoff: the 3 largest are named, never an empty list" '[ "$(printf "%s\n" "$out" | grep -c "^  \* ")" = 3 ] && ! contains "$out" "System"' "$out"
out=$(src 'init_monitor_state; collect_procs fast; VERDICT=HIGH; build_recommendations')
check "advice from RSS says that real use is higher" 'contains "$out" "resident memory only"' "$out"
check "advice from footprints carries no RSS caveat" '! contains "$out8" "resident memory only"' "$out8"
# The HIGH message must not claim "nothing is closed automatically" when an opt-in rule is on.
brief() { src "session_init; collect_procs precise; VERDICT_REASON=test; S_RECO_PRINTED=1; $1; session_pressure_brief"; }
out=$(brief 'true')
check "HIGH message, auto rules off: nothing is closed automatically" 'contains "$out" "nothing is closed automatically" && contains "$out" "f = free up memory"' "$out"
out=$(brief 'AUTO_STOP_IDLE_TSSERVER=true')
check "HIGH message, TypeScript rule on: says so, no false claim" 'contains "$out" "Only your opt-in rule(s) may act: idle TypeScript servers, after a 60s notice" && ! contains "$out" "nothing is closed automatically"' "$out"
out=$(brief 'AUTO_STOP_IDLE_TSSERVER=true; AUTO_STOP_IDLE_DEVSERVER=true')
check "HIGH message, both rules on: names both" 'contains "$out" "idle TypeScript servers and idle dev servers"' "$out"
out=$(reco 'MEM_TOTAL_MB=8192; VERDICT=OK')
check "no pressure: no consumer list" '! printf "%s\n" "$out" | grep -q "^  \* " && ! contains "$out" "Memory is"' "$out"
out=$(src 'MEM_TOTAL_MB=65536; advice_for_group ollama "Local AI" 1 4000')
check "local AI advice uses the detected RAM, not 8 GB" 'contains "$out" "64.0 GB RAM" && ! contains "$out" "8 GB"' "$out"

# Commands printed for the user to paste are quoted safely, whatever the path contains (S2).
qbad=""
for p in "plain" "with space" "it's" "x'; touch $TMP/pwned; echo '" "\$(touch $TMP/pwned)" "back\`tick\`" "a\"b" "trailing\\"; do
  q=$(PATH="$STUBS:$PATH" MPM_SOURCE_ONLY=1 "$SH" -c '. "$0"; shell_quote "$1"' "$SCRIPT" "$p")
  back=$(eval "printf '%s' $q")
  [ "$back" = "$p" ] || qbad="$qbad bash:[$p]->[$q]->[$back]"
  if command -v zsh >/dev/null 2>&1; then
    back=$(zsh -fc "printf '%s' $q")
    [ "$back" = "$p" ] || qbad="$qbad zsh:[$p]->[$q]->[$back]"
  fi
done
check "shell_quote: tricky paths round-trip in bash and zsh, nothing executed" '[ -z "$qbad" ] && [ ! -e "$TMP/pwned" ]' "$qbad"

out=$(src 'run_with_timeout 1 sleep 30; echo "rc=$?"')
t1=$(date +%s)
check "run_with_timeout stops slow commands" 'contains "$out" "rc=143" && [ $((t1 - t0)) -le 4 ]' "$out"

# ---------------------------------------------------------------------------
echo "[modes]"
out=$(mpm --once 2>&1); rc=$?
check "--once renders all sections" '[ $rc = 0 ] && contains "$out" "MEMORY" && contains "$out" "TOP MEMORY" && contains "$out" "TOP CPU" && contains "$out" "DEVELOPMENT" && contains "$out" "RECOMMENDATIONS"' "$out"
check "--once: memory math in output" 'contains "$out" "Used 6.4 GB = app 3.0 GB + wired 1.4 GB + compressed 2.0 GB"' "$out"
out=$(mpm --live </dev/null 2>&1); rc=$?
check "--live without a terminal prints once and exits" '[ $rc = 0 ] && contains "$out" "RECOMMENDATIONS"' "$out"
out=$(mpm --report 2>&1); rc=$?
rep=$(ls "$TMP"/data/reports/report-*.txt 2>/dev/null | head -n 1)
check "--report saves a file" '[ $rc = 0 ] && [ -f "$rep" ] && contains "$out" "Recommended actions"' "$out"
check "report contains no command lines or secrets" '! grep -qE "supersecret|hunter2|sk-abc|/Users/me|SECRETSERIAL|--token" "$rep"'
perms=$(ls -l "$rep" | cut -c1-10)
check "report is private (-rw-------)" '[ "$perms" = "-rw-------" ]' "$perms"
out=$(mpm --stop </dev/null 2>&1)
check "--stop when nothing runs" 'contains "$out" "not running"' "$out"

# --free: a ranked plan; nothing happens without a choice and a confirmation.
out=$(mpm --free </dev/null 2>&1); rc=$?
check "--free without input: plan shown, nothing changed" '[ $rc = 0 ] && contains "$out" "FREE UP MEMORY - ranked plan" && contains "$out" "Nothing was changed." && contains "$out" "close heavy tabs" && contains "$out" "quit app" && contains "$out" "stop process (PID"' "$out"
sizes=$(printf '%s\n' "$out" | sed -n 's/^ *[0-9][0-9]*) .* ~\([0-9.]*\) \([MG]B\) .*/\1 \2/p' | awk '{ print ($2 == "GB" ? $1 * 1024 : $1) }')
check "--free: steps ranked by size, largest first" '[ -n "$sizes" ] && [ "$sizes" = "$(printf "%s\n" "$sizes" | sort -nr)" ]' "$sizes"
item() { printf '%s\n' "$out" | grep -E "^ *[0-9]+\) $1 " | head -n 1 | sed -E 's/^ *([0-9]+)\).*/\1/'; }
nCur=$(item Cursor); nBrave=$(item Brave)
calls0=$(cat "$MPM_FAKE_STATE/osascript.calls" 2>/dev/null | wc -l | tr -d ' ')
out=$(printf '%s\nn\n\n' "$nCur" | mpm --free 2>&1); rc=$?
calls1=$(cat "$MPM_FAKE_STATE/osascript.calls" 2>/dev/null | wc -l | tr -d ' ')
check "--free: declining a quit sends nothing" '[ $rc = 0 ] && [ -n "$nCur" ] && contains "$out" "quitting Cursor stops its AI agents" && contains "$out" "Cancelled." && contains "$out" "Nothing was changed." && [ "$calls1" = "$calls0" ]' "$out"
out=$(printf '%s\ny\n\n' "$nCur" | mpm --free 2>&1)
calls2=$(cat "$MPM_FAKE_STATE/osascript.calls" 2>/dev/null | wc -l | tr -d ' ')
check "--free: an approved quit asks the app to quit normally (stubbed, refused)" 'grep -q "to quit" "$MPM_FAKE_STATE/osascript.calls" && [ "$calls2" -gt "$calls1" ] && contains "$out" "macOS did not allow the quit request" && contains "$out" "Nothing was changed."' "$out"
out=$(printf '%s\n\n' "$nBrave" | mpm --free 2>&1)
check "--free: a browser step is read-only advice" '[ -n "$nBrave" ] && contains "$out" "BROWSER MEMORY" && contains "$out" "Shift+Esc" && contains "$out" "Nothing was changed."' "$out"
out=$(printf 'x\n99\n\n' | mpm --free 2>&1)
check "--free: invalid choices do nothing" 'contains "$out" "Not a number. Nothing was done." && contains "$out" "No such entry. Nothing was done." && contains "$out" "Nothing was changed."' "$out"
rm -f "$MPM_FAKE_STATE/osascript.calls"   # later tests check that Finder/AppleScript is never called

# Optional tools absent or unusable. On macOS the real tools always exist in /usr/bin and
# /usr/sbin (the script adds those to PATH), so "missing" is simulated by stubs that fail.
DEGRADED="$TMP/degraded"; mkdir -p "$DEGRADED"
for f in "$STUBS"/*; do
  case ${f##*/} in top|pmset|lsof|memory_pressure|system_profiler) cp "$STUBS/unavailable" "$DEGRADED/${f##*/}" ;; *) cp "$f" "$DEGRADED/" ;; esac
done
out=$(PATH="$DEGRADED:$PATH" "$SH" "$SCRIPT" --once --config "$CFG" 2>&1); rc=$?
check "optional tools unavailable (top, pmset, lsof): still works, uses RSS" '[ $rc = 0 ] && contains "$out" "RSS MB" && ! contains "$out" "Battery"' "$out"
NOVM="$TMP/novm"; mkdir -p "$NOVM"; cp "$STUBS"/* "$NOVM/"; rm -f "$NOVM/vm_stat"
if ! PATH="/usr/bin:/bin:/usr/sbin:/sbin" command -v vm_stat >/dev/null 2>&1; then
  out=$(PATH="$NOVM:$PATH" "$SH" "$SCRIPT" --once --config "$CFG" 2>&1); rc=$?
  check "required tool missing (vm_stat): clear error, exit 1" '[ $rc = 1 ] && contains "$out" "required system utilities not found: vm_stat"' "$out"
else
  skip "required tool missing" "real vm_stat present on this system"
fi

# Ctrl+C on work mode: must stop promptly, print a summary, remove its pidfile, leave no children.
set -m
PATH="$STUBS:$PATH" "$SH" "$SCRIPT" --work --config "$CFG" > "$TMP/work.out" 2>&1 < /dev/null &
WP=$!; CHILDREN="$CHILDREN $WP"
sleep 3
kids_before=$(ps -o pid= -o ppid= -A 2>/dev/null | awk -v p="$WP" '$2 == p' | wc -l | tr -d ' ')
kill -INT "$WP"
t0=$(date +%s); wait "$WP"; rc=$?; t1=$(date +%s)
set +m
sleep 1
kids_after=$(ps -o pid= -o ppid= -A 2>/dev/null | awk -v p="$WP" '$2 == p' | wc -l | tr -d ' ')
check "Ctrl+C stops work mode within 3 s" '[ $((t1 - t0)) -le 3 ]' "took $((t1 - t0))s"
check "work mode prints summary on Ctrl+C" 'grep -q "WORK SESSION SUMMARY" "$TMP/work.out"' "$(cat "$TMP/work.out")"
check "work session report saved on Ctrl+C" 'ls "$TMP"/data/reports/report-session-*.txt >/dev/null 2>&1 && grep -q "Saved: .*report-session-" "$TMP/work.out"' "$(ls "$TMP/data/reports"; tail -n 5 "$TMP/work.out")"
check "work mode removes its pidfile" '[ ! -e "$TMP/data/state/work.pid" ]'
check "no child processes left behind (had $kids_before while running)" '[ "$kids_after" = 0 ]'
check "work mode logged start/stop" 'grep -q "work mode started" "$TMP/data/logs/events.log" && grep -q "work mode stopped" "$TMP/data/logs/events.log"'

# Started through a symlink (README: ln -s ... ~/bin/mpm): the command line no longer contains
# the script's name, yet a second --work must be refused and --stop must find and stop it.
LINK="$TMP/mpm"; ln -s "$SCRIPT" "$LINK"
PATH="$STUBS:$PATH" "$SH" "$LINK" --work --config "$CFG" > "$TMP/work2.out" 2>&1 < /dev/null &
WL=$!; disown "$WL" 2>/dev/null; CHILDREN="$CHILDREN $WL"
i=0; while [ "$i" -lt 50 ] && [ "$(sed -n 2p "$TMP/data/state/work.pid" 2>/dev/null)" = "" ]; do sleep 0.1; i=$((i + 1)); done
# A second instance that is wrongly allowed would run forever: give it 5 s, then stop it.
PATH="$STUBS:$PATH" "$SH" "$LINK" --work --config "$CFG" > "$TMP/work3.out" 2>&1 < /dev/null &
W3=$!; CHILDREN="$CHILDREN $W3"
i=0; while [ "$i" -lt 50 ] && kill -0 "$W3" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$W3" 2>/dev/null; then kill -TERM "$W3"; wait "$W3" 2>/dev/null; rc="still running"; else wait "$W3"; rc=$?; fi
out=$(cat "$TMP/work3.out")
check "symlinked work mode: second --work refused" '[ $rc = 1 ] && contains "$out" "already running (PID $WL)"' "$out"
out=$(PATH="$STUBS:$PATH" "$SH" "$LINK" --stop --config "$CFG" 2>&1 < /dev/null)
i=0; while [ "$i" -lt 30 ] && kill -0 "$WL" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
check "symlinked work mode: --stop finds and stops it" 'contains "$out" "Stop signal sent to work mode (PID $WL)" && ! kill -0 "$WL" 2>/dev/null && [ ! -e "$TMP/data/state/work.pid" ]' "$out"

PIDF="$TMP/data/state/work.pid"; LOCKD="$TMP/data/state/work.lock"
# Runs a --work that must exit on its own; one wrongly allowed to start is stopped after 6 s.
bounded_work() {   # outfile -> prints the exit code, or "still running"
  PATH="$STUBS:$PATH" "$SH" "$SCRIPT" --work --config "$CFG" > "$1" 2>&1 < /dev/null &
  local p=$! i=0
  while [ "$i" -lt 60 ] && kill -0 "$p" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$p" 2>/dev/null; then kill -TERM "$p"; wait "$p" 2>/dev/null; echo "still running"; else wait "$p"; echo $?; fi
}
running() { kill -0 "$1" 2>/dev/null && ! /bin/ps -o stat= -p "$1" 2>/dev/null | grep -q Z; }

# Work mode started from the menu (item 11): no --work on its command line, yet it must be
# recognised. Before the fix a second --work started and --stop deleted the live pidfile.
MF="$TMP/menu11.fifo"; mkfifo "$MF"; MO="$TMP/menu11.out"
# Started in one time zone, stopped from another (travel, DST): the start time must still match.
TZ=Asia/Tokyo PATH="$STUBS:$PATH" "$SH" "$SCRIPT" --config "$CFG" < "$MF" > "$MO" 2>&1 &
MW=$!; CHILDREN="$CHILDREN $MW"
exec 6>"$MF"
printf '11\n' >&6
i=0; while [ "$i" -lt 100 ] && [ "$(head -n 1 "$PIDF" 2>/dev/null)" != "$MW" ]; do sleep 0.1; i=$((i + 1)); done
check "menu work mode: pidfile holds the menu process and its start time" '[ "$(head -n 1 "$PIDF" 2>/dev/null)" = "$MW" ] && [ -n "$(sed -n 2p "$PIDF")" ]' "$(tail -n 5 "$MO")"
rc=$(bounded_work "$TMP/menu11-second.out")
check "menu work mode: a second --work is refused" '[ "$rc" = 1 ] && grep -q "already running (PID $MW)" "$TMP/menu11-second.out"' "rc=$rc; $(cat "$TMP/menu11-second.out")"
check "menu work mode: the refused --work left the pidfile alone" '[ "$(head -n 1 "$PIDF" 2>/dev/null)" = "$MW" ]'
out=$(TZ=America/New_York mpm --stop < /dev/null 2>&1)
i=0; while [ "$i" -lt 100 ] && ! grep -q "WORK SESSION SUMMARY" "$MO"; do sleep 0.1; i=$((i + 1)); done
check "menu work mode: --stop (other time zone) finds it; the session ends, the menu stays" 'contains "$out" "Stop signal sent to work mode (PID $MW)" && grep -q "WORK SESSION SUMMARY" "$MO" && running "$MW"' "$out / $(tail -n 5 "$MO")"
i=0; while [ "$i" -lt 30 ] && [ -e "$PIDF" ]; do sleep 0.1; i=$((i + 1)); done
check "menu work mode: pidfile removed when its session ends" '[ ! -e "$PIDF" ]'
printf '13\n' >&6; exec 6>&-
i=0; while [ "$i" -lt 50 ] && running "$MW"; do sleep 0.1; i=$((i + 1)); done
wait "$MW" 2>/dev/null; rc=$?
check "menu work mode: menu exits normally afterwards" '[ $rc = 0 ] && ! running "$MW"' "rc=$rc"

# A pidfile naming a live process that is NOT the owner must never be signalled by --stop.
ln -s "$(PATH=/usr/bin:/bin command -v sleep)" "$TMP/reuse-sleep"
"$TMP/reuse-sleep" 120 & RP=$!; disown "$RP" 2>/dev/null; CHILDREN="$CHILDREN $RP"
printf '%s\nMon Jan  1 00:00:00 2001\n' "$RP" > "$PIDF"
out=$(mpm --stop < /dev/null 2>&1)
check "--stop ignores a reused PID (start time differs) and removes the stale pidfile" 'contains "$out" "not running" && running "$RP" && [ ! -e "$PIDF" ]' "$out"
printf '%s\n' "$RP" > "$PIDF"
out=$(mpm --stop < /dev/null 2>&1)
check "--stop ignores an old-style pidfile naming an unrelated process" 'contains "$out" "not running" && running "$RP" && [ ! -e "$PIDF" ]' "$out"
rc=$( printf '%s\nMon Jan  1 00:00:00 2001\n' "$RP" > "$PIDF"; bounded_work "$TMP/reuse-work.out")
check "stale pidfile (reused PID) does not block a new --work" '[ "$rc" = "still running" ] && grep -q "WORK SESSION" "$TMP/reuse-work.out"' "rc=$rc; $(head -n 5 "$TMP/reuse-work.out")"
kill -TERM "$RP" 2>/dev/null
rm -f "$PIDF"

# Atomic lock (B2). A lock held by an instance that is starting: --work waits ~3 s, then gives up.
mkdir "$LOCKD"
rc=$(bounded_work "$TMP/lock-fresh.out")
check "lock held by a starting instance: --work gives up (exit 1), claims nothing" '[ "$rc" = 1 ] && grep -q "starting right now" "$TMP/lock-fresh.out" && [ ! -e "$PIDF" ] && [ -d "$LOCKD" ]' "rc=$rc; $(cat "$TMP/lock-fresh.out")"
out=$(mpm --stop < /dev/null 2>&1)
check "--stop does not remove a lock it does not hold" 'contains "$out" "not running" && [ -d "$LOCKD" ]' "$out"
# A lock left by an instance killed while holding it (older than a minute) is recovered.
touch -t 202001010000 "$LOCKD"
rc=$(bounded_work "$TMP/lock-stale.out")
check "stale lock (killed instance) is recovered: --work starts" '[ "$rc" = "still running" ] && grep -q "WORK SESSION" "$TMP/lock-stale.out"' "rc=$rc; $(head -n 5 "$TMP/lock-stale.out")"
check "lock is released once the pidfile is claimed" '[ ! -d "$LOCKD" ]'
rm -f "$PIDF"

# Several work modes started at the same moment: exactly one may run.
RACE=""
for n in 1 2 3 4 5; do
  PATH="$STUBS:$PATH" "$SH" "$SCRIPT" --work --config "$CFG" > "$TMP/race$n.out" 2>&1 < /dev/null &
  RACE="$RACE $!"
done
CHILDREN="$CHILDREN $RACE"
sleep 5
alive=""; for p in $RACE; do running "$p" && alive="$alive $p"; done
refused=$(grep -lE "already running|starting right now" "$TMP"/race[1-5].out 2>/dev/null | wc -l | tr -d ' ')
check "5 work modes started at once: exactly one runs, 4 refused" '[ "$(echo $alive | wc -w | tr -d " ")" = 1 ] && [ "$refused" = 4 ]' "alive:$alive refused:$refused"
check "the survivor owns the pidfile; no lock left behind" '[ "$(head -n 1 "$PIDF" 2>/dev/null)" = "$(echo $alive)" ] && [ ! -d "$LOCKD" ]' "pidfile: $(head -n 1 "$PIDF" 2>/dev/null) alive:$alive"
out=$(mpm --stop < /dev/null 2>&1)
for p in $RACE; do i=0; while [ "$i" -lt 50 ] && running "$p"; do sleep 0.1; i=$((i + 1)); done; done
alive=""; for p in $RACE; do running "$p" && { alive="$alive $p"; kill -TERM "$p"; }; done
check "--stop stops the survivor; nothing left running" 'contains "$out" "Stop signal sent" && [ -z "$alive" ] && [ ! -e "$PIDF" ]' "$out / alive:$alive"

# Ctrl+C in the interactive menu exits with 130 and leaves the terminal alone.
FIFO="$TMP/fifo"; mkfifo "$FIFO"
set -m
PATH="$STUBS:$PATH" "$SH" "$SCRIPT" --config "$CFG" < "$FIFO" > "$TMP/menu.out" 2>&1 &
MP=$!; CHILDREN="$CHILDREN $MP"
exec 7>"$FIFO"
sleep 2
kill -INT "$MP"; wait "$MP"; rc=$?
set +m
exec 7>&-
check "Ctrl+C in menu exits cleanly (130)" '[ $rc = 130 ]' "rc=$rc"

out=$(printf '2\n3\n4\n1\nb\n5\n6\n7\n8\n9\n1\n6\n9\nb\n10\n3\nb\n12\n99\n13\n' | mpm 2>&1); rc=$?
check "every menu item runs and exits 0" '[ $rc = 0 ] && contains "$out" "MEMORY DIAGNOSTICS" && contains "$out" "CPU DIAGNOSTICS" && contains "$out" "STARTUP DISK" && contains "$out" "CURSOR DIAGNOSTICS" && contains "$out" "LISTENING SERVERS" && contains "$out" "SAFE CLEANUP" && contains "$out" "BEFORE -> NOW" && contains "$out" "INTERACTIVE PROCESS MANAGEMENT" && contains "$out" "Unknown choice"' "$(printf '%s\n' "$out" | tail -n 20)"
check "dev view shows ports and redacts secrets" 'contains "$out" "3000" && contains "$out" "8000" && ! contains "$out" "supersecret" && ! contains "$out" "hunter2"'

# ---------------------------------------------------------------------------
echo "[work session]"
# Real --work sessions whose input is a FIFO: 'n' takes a sample immediately, so the test
# controls timing instead of waiting for the interval. Pressure, disk and the process
# table come from override files the stubs read. The dev process stopped here is a
# throw-away process (a symlink named node -> sleep inside the temporary folder).
WS="$TMP/ws"; mkdir -p "$WS"
CFGW="$WS/c.env"
printf 'DATA_DIR=%s/wdata\nNOTIFICATIONS_ENABLED=false\nCOLOR=never\nWORK_INTERVAL_SEC=1800\nWORK_RELAXED_INTERVAL_SEC=3600\nWORK_RELAX_AFTER_SAMPLES=3\nSUSTAINED_SAMPLES=2\nKILL_GRACE_SEC=3\n' "$TMP" > "$CFGW"
rm -f "$MPM_FAKE_STATE/pressure" "$MPM_FAKE_STATE/df.txt" "$MPM_FAKE_STATE/ps.txt"
trash_n0=$(ls -A "$HOME/.Trash" | wc -l | tr -d ' ')
mkdir -p "$TMP/devbin"; ln -s "$(PATH=/usr/bin:/bin command -v sleep)" "$TMP/devbin/node"
"$TMP/devbin/node" 300 & DV=$!; disown "$DV" 2>/dev/null; CHILDREN="$CHILDREN $DV"
dev_alive() { case $(/bin/ps -o args= -p "$DV" 2>/dev/null) in "$TMP/devbin/node "*) return 0 ;; esac; return 1; }
i=0; while [ "$i" -lt 30 ] && ! dev_alive; do sleep 0.1; i=$((i + 1)); done
# Process table = fixture + the throw-away "node" (the largest dev process, so it is entry 1).
{ cat "$MPM_FIX/ps.txt"; printf '%5s %5s @UID@ 3000000   0.0 %s\n' "$DV" "$$" "$TMP/devbin/node"
  printf ' 1801  1004 @UID@  400000   0.0 tsserver[6.0.3]: semantic\n 1802  1005 @UID@  300000   0.0 tsserver[6.0.3]: semantic\n'; } > "$MPM_FAKE_STATE/ps.txt"
echo "1801 1802 1899" > "$MPM_FAKE_STATE/fake_pids"   # made-up rows: never looked up in the real system
WF="$WS/in.fifo"; mkfifo "$WF"; WO="$WS/out.txt"
PATH="$STUBS:$PATH" "$SH" "$SCRIPT" --work --config "$CFGW" < "$WF" > "$WO" 2>&1 &
WP2=$!; CHILDREN="$CHILDREN $WP2"
exec 9>"$WF"
send() { printf '%s\n' "$1" >&9; }
waitfor() {   # text [count] -> up to 15 s until text appears count times in $WO
  local i=0; while [ "$i" -lt 150 ]; do [ "$(grep -c -- "$1" "$WO" 2>/dev/null)" -ge "${2:-1}" ] && return 0; sleep 0.1; i=$((i + 1)); done; return 1
}
sample() { send n; waitfor "| sample $1\$"; }

check "session starts: banner, keys and first sample" 'waitfor "| sample 1$" && grep -q "Keys: f free up memory" "$WO" && [ -f "$TMP/wdata/state/work.pid" ]' "$(cat "$WO")"
sample 2; sample 3
check "adaptive polling: interval relaxes after 3 calm samples" 'grep -q "Auto: sampling interval 1800s -> 3600s (stable for 3 samples)" "$WO"' "$(tail -n 5 "$WO")"
echo "2 18" > "$MPM_FAKE_STATE/pressure"
sample 4
check "elevated pressure: normal interval again, one concise hint" 'grep -q "Auto: sampling interval 3600s -> 1800s (memory status WATCH)" "$WO" && [ "$(grep -c "Memory is getting tight" "$WO")" = 1 ]' "$(tail -n 8 "$WO")"
check "one elevated sample is not HIGH (sustained threshold)" '! grep -q "HIGH MEMORY PRESSURE" "$WO"'
sample 5
check "sustained pressure: HIGH with likely causes and options" 'grep -q "Measuring per-process memory" "$WO" && grep -q "HIGH MEMORY PRESSURE" "$WO" && grep -q "Development processes: " "$WO" && grep -q "d = diagnose" "$WO" && grep -q "nothing is closed automatically" "$WO"' "$(tail -n 20 "$WO")"
check "warning's advice uses footprints measured first (not RSS)" '[ "$(grep -B1 "^Recommended:" "$WO" | head -n 1)" = "Measuring per-process memory (about 2 s)..." ] && ! grep -q "resident memory only" "$WO"' "$(grep -B3 -A4 "^Recommended:" "$WO")"
check "high pressure alone stops nothing" 'dev_alive'
send c
check "expensive disk scan deferred under high pressure (asked, not run)" 'waitfor "Open the disk tools anyway" && send n && waitfor "Deferred. Press c again" && ! grep -q "DISK DIAGNOSTICS" "$WO"' "$(tail -n 5 "$WO")"
send k
check "dev processes listed largest first, with what breaks" 'waitfor "Number to stop gracefully" && grep -q " 1) PID $DV " "$WO" && grep -q "if stopped:" "$WO" && grep -q "Low CPU does not mean unused" "$WO"' "$(tail -n 30 "$WO")"
check "duplicate TypeScript language servers are pointed out, not stopped" 'grep -q "2 TypeScript language servers" "$WO" && grep -q "TypeScript: Restart TS Server" "$WO"' "$(tail -n 30 "$WO")"
send 1
check "selected process goes through the full review" 'waitfor "Type .yes. to send SIGTERM" && grep -q "PID:      $DV" "$WO"' "$(tail -n 15 "$WO")"
send no
check "declining at review sends nothing" 'waitfor "Cancelled. Nothing was sent." && dev_alive' "$(tail -n 5 "$WO")"
send k; waitfor "Number to stop gracefully" 2; send 1; waitfor "Type .yes. to send SIGTERM" 2; send yes
check "approved: graceful SIGTERM, process exits, no SIGKILL" 'waitfor "PID $DV exited." && ! dev_alive && ! grep -q "SIGKILL sent" "$WO"' "$(tail -n 15 "$WO")"
grep -v "$TMP/devbin/node" "$MPM_FAKE_STATE/ps.txt" | grep -v "Brave Browser" > "$WS/ps2"; mv "$WS/ps2" "$MPM_FAKE_STATE/ps.txt"
sample 6
echo "1 50" > "$MPM_FAKE_STATE/pressure"; sleep 1
sample 7
check "before/after measured 2 samples after the approved action" 'grep -q "Measured after .stop node.: free estimate 18% -> 50%" "$WO"' "$(tail -n 14 "$WO")"
check "recovery detected; changes reported as correlation" 'grep -q "RECOVERY - memory status is OK" "$WO" && grep -q "Brave -0.7 GB (no longer running)" "$WO" && grep -q "correlation, not proof" "$WO" && grep -q "approved: stopped node" "$WO"' "$(tail -n 14 "$WO")"
send t
check "top consumers: detailed (footprint) sample taken on request" 'waitfor "TOP CONSUMERS (measured now)" && waitfor "MEM MB"' "$(tail -n 8 "$WO")"
send t
check "asked again before the next sample: detailed sample reused" 'waitfor "reused, no new measurement"' "$(tail -n 5 "$WO")"
send s
check "status on request" 'waitfor "Mode NORMAL | sampling every 1800s"' "$(tail -n 5 "$WO")"
send i; waitfor "PID to inspect"; send "$$"
check "inspect is read-only and reports protection" 'waitfor "read-only; nothing is sent to it" && waitfor "Protected: PID $$ is this manager or the shell"' "$(tail -n 10 "$WO")"
send a
check "session actions: automatic and your decisions" 'waitfor "THIS SESSION" && waitfor "declined: stopping node" && grep -q "deferred a disk scan" "$WO"' "$(tail -n 12 "$WO")"
send d
check "diagnosis offers choices with benefit and risk" 'waitfor "Choice \[4\]" && grep -q "1) Browser memory" "$WO" && grep -q "Benefit: up to roughly" "$WO"' "$(tail -n 20 "$WO")"
send 4
check "ignoring keeps monitoring" 'waitfor "Continuing to monitor." && kill -0 $WP2' "$(tail -n 3 "$WO")"

# Free-up plan (key f): ranked, and the chosen step goes through the full review and typed yes.
"$TMP/devbin/node" 300 & DV2=$!; disown "$DV2" 2>/dev/null; CHILDREN="$CHILDREN $DV2"
dv2_alive() { case $(/bin/ps -o args= -p "$DV2" 2>/dev/null) in "$TMP/devbin/node "*) return 0 ;; esac; return 1; }
i=0; while [ "$i" -lt 30 ] && ! dv2_alive; do sleep 0.1; i=$((i + 1)); done
printf '%5s %5s @UID@ 2500000   0.0 %s\n' "$DV2" "$$" "$TMP/devbin/node" >> "$MPM_FAKE_STATE/ps.txt"
send f
check "free-up plan: ranked steps, each with what it costs" 'waitfor "FREE UP MEMORY - ranked plan" && waitfor "Number to act on" && grep -q "stop process (PID $DV2)" "$WO" && grep -q "quit app" "$WO" && grep -q "If stopped:" "$WO" && dv2_alive' "$(tail -n 30 "$WO")"
nDV2=$(sed -n '/FREE UP MEMORY - ranked plan/,$p' "$WO" | grep "stop process (PID $DV2)" | tail -n 1 | sed -E 's/^ *([0-9]+)\).*/\1/')
send "$nDV2"
check "free-up plan: the chosen step opens the full review; nothing sent yet" 'waitfor "Type .yes. to send SIGTERM" 3 && grep -q "PID:      $DV2" "$WO" && dv2_alive' "$(tail -n 15 "$WO")"
send yes
waitfor "PID $DV2 exited."
grep -v "$TMP/devbin/node" "$MPM_FAKE_STATE/ps.txt" > "$WS/ps3"; mv "$WS/ps3" "$MPM_FAKE_STATE/ps.txt"
check "free-up plan: approved step done, effect measured, plan offered again" '! dv2_alive && waitfor "Effect so far: macOS free estimate" && waitfor "Number to act on" 2' "$(tail -n 20 "$WO")"
check "free-up plan: the refreshed plan no longer lists the stopped process" '! sed -n "/Effect so far/,\$p" "$WO" | grep -q "PID $DV2"' "$(sed -n '/Effect so far/,$p' "$WO")"
send ""
check "free-up plan: Enter ends it with a before/after summary" 'waitfor "FREE-UP SUMMARY" && waitfor "Done: node" && waitfor "Since the plan started: macOS free estimate"' "$(tail -n 8 "$WO")"
send a
check "free-up plan: decision recorded in the session" 'waitfor "approved (free-up plan): stopped node (PID $DV2, sigterm)"' "$(tail -n 12 "$WO")"
send r
check "report on demand is saved" 'waitfor "Saved: .*report-session-"' "$(tail -n 3 "$WO")"
send q; exec 9>&-
i=0; while [ "$i" -lt 100 ] && kill -0 "$WP2" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
sum=$(sed -n '/WORK SESSION SUMMARY/,$p' "$WO")
check "q stops the session cleanly" '! kill -0 "$WP2" 2>/dev/null && [ ! -e "$TMP/wdata/state/work.pid" ]' "$sum"
check "summary: pressure share, peak, swap, disk" 'contains "$sum" "Pressure:    OK" && contains "$sum" "peak status HIGH" && contains "$sum" "lowest macOS free estimate 18%" && contains "$sum" "Swap:" && contains "$sum" "Disk:"' "$sum"
check "summary: automatic actions incl. measured manager CPU" 'contains "$sum" "sampling interval 1800s -> 3600s" && contains "$sum" "manager CPU so far" && contains "$sum" "reused a detailed sample" && contains "$sum" "detailed top samples"' "$sum"
check "summary: approved/declined actions and measured effect" 'contains "$sum" "approved: stopped node" && contains "$sum" "declined: stopping node" && contains "$sum" "after '"'"'stop node'"'"'" && contains "$sum" "correlation, not proof"' "$sum"
check "summary: remaining bottlenecks and honest limits" 'contains "$sum" "Remaining bottlenecks" && contains "$sum" "it cannot add RAM"' "$sum"
rep=$(ls -t "$TMP"/wdata/reports/report-session-*.txt 2>/dev/null | head -n 1)
check "final report saved without command lines or paths" '[ -f "$rep" ] && grep -q "WORK SESSION SUMMARY" "$rep" && ! grep -qE "devbin|--token|supersecret|/Users/me" "$rep"' "$(cat "$rep" 2>/dev/null | head -n 5)"
check "session never touched the Trash or Finder" '[ "$(ls -A "$HOME/.Trash" | wc -l | tr -d " ")" = "$trash_n0" ] && [ ! -f "$MPM_FAKE_STATE/osascript.calls" ]'

# Second session: low disk, optional tools unavailable, and Ctrl+C with input attached.
sed 's/ 43200000 / 15000000 /' "$MPM_FIX/df.txt" > "$MPM_FAKE_STATE/df.txt"
rm -f "$MPM_FAKE_STATE/pressure"
WF="$WS/in2.fifo"; mkfifo "$WF"; WO="$WS/out2.txt"
set -m
PATH="$DEGRADED:$PATH" "$SH" "$SCRIPT" --work --config "$CFGW" < "$WF" > "$WO" 2>&1 &
WP3=$!; CHILDREN="$CHILDREN $WP3"
set +m
exec 9>"$WF"
check "low disk: warned once with a hint; nothing deleted" 'waitfor "Disk free space is LOW" && [ "$(grep -c "Press c to review cleanup candidates" "$WO")" = 1 ] && [ "$(ls -A "$HOME/.Trash" | wc -l | tr -d " ")" = "$trash_n0" ]' "$(cat "$WO")"
send k
check "dev list works without lsof (no ports or folders)" 'waitfor "Number to stop gracefully" && send "" && waitfor "Cancelled. Nothing was sent."' "$(tail -n 12 "$WO")"
kill -INT "$WP3"; t0=$(date +%s); wait "$WP3"; t1=$(date +%s)
exec 9>&-
check "Ctrl+C with input attached: stops within 3 s, summary and report" '[ $((t1 - t0)) -le 3 ] && grep -q "WORK SESSION SUMMARY" "$WO" && grep -q "Saved: .*report-session-" "$WO" && [ ! -e "$TMP/wdata/state/work.pid" ]' "took $((t1 - t0))s; $(tail -n 5 "$WO")"
rm -f "$MPM_FAKE_STATE/df.txt" "$MPM_FAKE_STATE/ps.txt"

# Opt-in automatic rule: idle TypeScript servers. Two throw-away "tsserver" processes
# (symlinks to sleep). Idleness is real (sleep uses no CPU); the test waits 62 s for it.
ln -s "$(PATH=/usr/bin:/bin command -v sleep)" "$TMP/devbin/tsserver"
start_ts() { "$TMP/devbin/tsserver" 300 & TSP=$!; disown "$TSP" 2>/dev/null; CHILDREN="$CHILDREN $TSP"; }
ts_alive() { case $(/bin/ps -o args= -p "$1" 2>/dev/null) in "$TMP/devbin/tsserver "*) return 0 ;; esac; return 1; }
start_ts; TS1=$TSP; start_ts; TS2=$TSP; sleep 0.3
{ cat "$MPM_FIX/ps.txt"
  printf '%5s  1004 @UID@ 2000000   0.0 %s\n' "$TS1" "$TMP/devbin/tsserver"
  printf '%5s  1005 @UID@ 1500000   0.0 %s\n' "$TS2" "$TMP/devbin/tsserver"; } > "$MPM_FAKE_STATE/ps.txt"
rm -f "$MPM_FAKE_STATE/pressure" "$MPM_FAKE_STATE/df.txt"
CFGA="$WS/auto.env"
printf 'DATA_DIR=%s/adata\nNOTIFICATIONS_ENABLED=false\nCOLOR=never\nWORK_INTERVAL_SEC=1800\nWORK_RELAX_AFTER_SAMPLES=0\nSUSTAINED_SAMPLES=1\nAUTO_STOP_IDLE_TSSERVER=true\nAUTO_TSSERVER_IDLE_MIN=1\nAUTO_ACTION_GRACE_SEC=10\nAUTO_MAX_INEFFECTIVE=1\n' "$TMP" > "$CFGA"
WF="$WS/in3.fifo"; mkfifo "$WF"; WO="$WS/out3.txt"
PATH="$STUBS:$PATH" "$SH" "$SCRIPT" --work --config "$CFGA" < "$WF" > "$WO" 2>&1 &
WP4=$!; CHILDREN="$CHILDREN $WP4"
exec 9>"$WF"
check "auto rule announced in the key help" 'waitfor "| sample 1$" && grep -q "x cancel a pending automatic action" "$WO"' "$(cat "$WO")"
sleep 62
sample 2
check "auto rule: idle TypeScript servers untouched while pressure is normal" '! grep -q "Auto in" "$WO" && ts_alive $TS1 && ts_alive $TS2' "$(tail -n 5 "$WO")"
echo "2 18" > "$MPM_FAKE_STATE/pressure"
sample 3
check "auto rule: under HIGH pressure the largest idle one is announced first" 'waitfor "Auto in 10s: stop idle TypeScript server PID $TS1 " && grep -q "Press x to cancel" "$WO"' "$(tail -n 12 "$WO")"
rm -f "$MPM_FAKE_STATE/pressure"
sample 4
check "auto rule: pressure eased during the notice, nothing sent" 'waitfor "memory pressure eased; PID $TS1 left running" && ts_alive $TS1' "$(tail -n 6 "$WO")"
echo "2 18" > "$MPM_FAKE_STATE/pressure"
sample 5
waitfor "Auto in 10s: stop idle TypeScript server PID $TS1 " 2; send x
check "auto rule: x cancels and that process is not selected again" 'waitfor "Cancelled. PID $TS1 will not be stopped automatically" && ts_alive $TS1' "$(tail -n 6 "$WO")"
sample 6
check "auto rule: next idle server announced, then SIGTERM after the notice" 'waitfor "Auto in 10s: stop idle TypeScript server PID $TS2 " && waitfor "Auto: sent SIGTERM to idle TypeScript server PID $TS2" && ! ts_alive $TS2 && ts_alive $TS1' "$(tail -n 8 "$WO")"
# Cursor would restart it: a new tsserver under the same parent with the same memory.
grep -v "^ *$TS2 " "$MPM_FAKE_STATE/ps.txt" > "$WS/ps3"; printf ' 1899  1005 @UID@ 1500000   0.0 tsserver[6.0.3]: semantic\n' >> "$WS/ps3"; mv "$WS/ps3" "$MPM_FAKE_STATE/ps.txt"
sample 7; sample 8
check "auto rule: restart detected, little freed, rule pauses itself" 'waitfor "Cursor restarted the TypeScript server" && waitfor "this rule is paused for the rest of the session"' "$(tail -n 8 "$WO")"
send q; exec 9>&-
i=0; while [ "$i" -lt 100 ] && kill -0 "$WP4" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
sum=$(sed -n '/WORK SESSION SUMMARY/,$p' "$WO")
check "auto rule: summary lists the automatic stop, the cancel and the measured result" 'contains "$sum" "stopped idle TypeScript server" && contains "$sum" "cancelled the automatic stop of PID $TS1 (ts" && contains "$sum" "rule paused for this session" && contains "$sum" "pressure eased during the notice period"' "$sum"
check "auto rule: never SIGKILL, only the selected process signalled" '! grep -q "SIGKILL" "$WO" && ts_alive $TS1 && grep -q "automatic SIGTERM to PID $TS2" "$TMP/adata/logs/events.log" && [ "$(grep -c "automatic SIGTERM" "$TMP/adata/logs/events.log")" = 1 ]' "$(grep ACTION "$TMP/adata/logs/events.log")"
rm -f "$MPM_FAKE_STATE/pressure" "$MPM_FAKE_STATE/ps.txt"

out=$(src "auto_terminate ts $TS1 'Thu Jan  1 00:00:00 2099 $TMP/devbin/tsserver'; echo rc=\$?")
check "auto_terminate refuses when the identity changed (PID reuse)" 'contains "$out" "changed since it was selected" && contains "$out" "rc=1" && ts_alive $TS1' "$out"
"$TMP/devbin/node" 300 & NV=$!; disown "$NV" 2>/dev/null; CHILDREN="$CHILDREN $NV"; sleep 0.3
out=$(src "auto_terminate ts $NV \"\$(proc_identity $NV)\"; echo rc=\$?")
check "auto_terminate refuses anything that is not a TypeScript server" 'contains "$out" "no longer a TypeScript server" && dev_alive_pid=$NV && case $(/bin/ps -o args= -p $NV) in "$TMP/devbin/node "*) true ;; *) false ;; esac' "$out"
out=$(src 'auto_terminate ts 1 x; echo rc=$?')
check "auto_terminate keeps every protection (PID 1)" 'contains "$out" "core system process" && contains "$out" "rc=1"' "$out"
kill -KILL "$NV" "$TS1" 2>/dev/null

# Opt-in automatic rule: idle dev servers. Five disposable "next dev" launchers (bash via a
# symlink named node_modules/.bin/next, running a script "dev" that starts a "next-server"
# child and stops it on SIGTERM, as Next.js does). Ports, client connections and folders come
# from the lsof stub. Only D1 is eligible; D2-D5 must be left alone, each for its own reason.
P2="$HOME/projects/web"; mkdir -p "$P2/node_modules/.bin"; echo '{}' > "$P2/package.json"
ln -s /bin/bash "$P2/node_modules/.bin/next"
ln -s "$(PATH=/usr/bin:/bin command -v sleep)" "$TMP/devbin/next-server"
printf 'trap '"'"'kill $c 2>/dev/null; exit 0'"'"' TERM\n"%s" 300 & c=$!\nwait $c\n' "$TMP/devbin/next-server" > "$P2/dev"
start_dev() { ( cd "$P2" && exec "$P2/node_modules/.bin/next" dev ) & DL=$!; disown "$DL" 2>/dev/null; CHILDREN="$CHILDREN $DL"
  local i=0; DC=""; while [ "$i" -lt 30 ] && [ -z "$DC" ]; do DC=$(pgrep -P "$DL" 2>/dev/null | head -n 1); sleep 0.1; i=$((i + 1)); done; CHILDREN="$CHILDREN $DC"; }
is_launcher() { case $(/bin/ps -ww -o args= -p "$1" 2>/dev/null) in "$P2/node_modules/.bin/next dev"*) return 0 ;; esac; return 1; }
is_nserver() { case $(/bin/ps -o args= -p "$1" 2>/dev/null) in "$TMP/devbin/next-server "*) return 0 ;; esac; return 1; }
start_dev; L1=$DL; C1=$DC; start_dev; L2=$DL; C2=$DC; start_dev; L3=$DL; C3=$DC; start_dev; L4=$DL; C4=$DC; start_dev; L5=$DL; C5=$DC
FS2="$WS/fake-dev"; mkdir -p "$FS2"
{ cat "$MPM_FIX/ps.txt"
  printf ' 1990  1499 @UID@   50000   0.0 claude\n'
  printf '%5s  1101 @UID@  900000   0.0 %s\n%5s %5s @UID@  100000   0.0 next-server (v16.1.1)\n' "$L1" "$P2/node_modules/.bin/next" "$C1" "$L1"
  printf '%5s  1990 @UID@ 5000000   0.0 %s\n%5s %5s @UID@  100000   0.0 next-server (v16.1.1)\n' "$L2" "$P2/node_modules/.bin/next" "$C2" "$L2"
  printf '%5s  1101 @UID@ 4500000   0.0 %s\n%5s %5s @UID@  100000   0.0 next-server (v16.1.1)\n' "$L3" "$P2/node_modules/.bin/next" "$C3" "$L3"
  printf '%5s  1101 @UID@ 4000000   0.0 %s\n%5s %5s @UID@  100000   0.0 next-server (v16.1.1)\n 1991 %5s @UID@   20000   0.0 tsc\n' "$L4" "$P2/node_modules/.bin/next" "$C4" "$L4" "$L4"
  printf '%5s  1101 @UID@ 3500000   0.0 %s\n%5s %5s @UID@  100000   0.0 next-server (v16.1.1)\n' "$L5" "$P2/node_modules/.bin/next" "$C5" "$L5"; } > "$FS2/ps.txt"
echo "1990 1991 2999" > "$FS2/fake_pids"
printf '%s\t3000\tLISTEN\n%s\t3001\tLISTEN\n%s\t3002\tLISTEN\n%s\t3002\tESTABLISHED\n%s\t3003\tLISTEN\n%s\t3004\tLISTEN\n' "$C1" "$C2" "$C3" "$C3" "$C4" "$C5" > "$FS2/tcp.tsv"
printf '%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t/\n' "$L1" "$P2" "$L2" "$P2" "$L3" "$P2" "$L4" "$P2" "$L5" > "$FS2/cwd.tsv"
CFGD="$WS/dev.env"
printf 'DATA_DIR=%s/ddata\nNOTIFICATIONS_ENABLED=false\nCOLOR=never\nWORK_INTERVAL_SEC=1800\nWORK_RELAX_AFTER_SAMPLES=0\nSUSTAINED_SAMPLES=1\nAUTO_STOP_IDLE_DEVSERVER=true\nAUTO_DEVSERVER_IDLE_MIN=1\nAUTO_ACTION_GRACE_SEC=10\nAUTO_COOLDOWN_MIN=1\n' "$TMP" > "$CFGD"
WF="$WS/in4.fifo"; mkfifo "$WF"; WO="$WS/out4.txt"
MPM_FAKE_STATE="$FS2" PATH="$STUBS:$PATH" "$SH" "$SCRIPT" --work --config "$CFGD" < "$WF" > "$WO" 2>&1 &
WP5=$!; CHILDREN="$CHILDREN $WP5"
exec 9>"$WF"
check "dev rule: off for TypeScript, on for dev servers, shown at start" 'waitfor "| sample 1$" && grep -q "idle TypeScript servers off, idle dev servers ON (1 min)" "$WO"' "$(head -n 12 "$WO")"
sleep 62
echo "2 18" > "$FS2/pressure"
sample 2
check "dev rule: a server started by an AI agent is left alone" 'waitfor "left PID $L2 alone: it was started by an AI agent (claude)"' "$(tail -n 12 "$WO")"
check "dev rule: a server with a connected browser/client is left alone" 'grep -q "left PID $L3 alone: a browser tab or client is connected to it" "$WO"' "$(tail -n 12 "$WO")"
check "dev rule: a server with a build running under it is left alone" 'grep -q "left PID $L4 alone: a tsc process is running under it" "$WO"' "$(tail -n 12 "$WO")"
check "dev rule: unverifiable project folder (ownership unclear) is left alone" 'grep -q "left PID $L5 alone: its project folder could not be verified" "$WO"' "$(tail -n 12 "$WO")"
check "dev rule: the verified idle server is announced with port and folder" 'grep -q "Auto in 10s: stop idle dev server PID $L1 on port 3000 (~/projects/web" "$WO" && grep -q "It is not restarted automatically" "$WO"' "$(tail -n 12 "$WO")"
check "dev rule: SIGTERM after the notice; the launcher stops its server" 'waitfor "Auto: sent SIGTERM to idle dev server PID $L1" && sleep 0.5 && ! is_launcher $L1 && ! is_nserver $C1' "$(tail -n 6 "$WO")"
check "dev rule: every protected server is still running" 'is_launcher $L2 && is_launcher $L3 && is_launcher $L4 && is_launcher $L5 && is_nserver $C2 && is_nserver $C5' "$(tail -n 4 "$WO")"
# Something serves port 3000 again: the stop did not help.
grep -v "^$C1	" "$FS2/tcp.tsv" > "$FS2/t2"; printf '2999\t3000\tLISTEN\n' >> "$FS2/t2"; mv "$FS2/t2" "$FS2/tcp.tsv"
grep -v "^ *$L1 \|^ *$C1 " "$FS2/ps.txt" > "$FS2/p2"; mv "$FS2/p2" "$FS2/ps.txt"
sample 3
check "dev rule: cooldown blocks a second automatic action right away" 'waitfor "waiting for the 1-minute cooldown"' "$(tail -n 6 "$WO")"
sample 4
check "dev rule: a server that comes back counts as ineffective" 'waitfor "port 3000 is served again (PID 2999)" && grep -q "ineffective 1 of 2" "$WO"' "$(tail -n 6 "$WO")"
# D3's client disconnects; after the cooldown it becomes eligible, then the session ends first.
grep -v "ESTABLISHED" "$FS2/tcp.tsv" > "$FS2/t3"; mv "$FS2/t3" "$FS2/tcp.tsv"
sleep 62
sample 5
check "dev rule: after the cooldown the next eligible server is announced" 'waitfor "Auto in 10s: stop idle dev server PID $L3 on port 3002"' "$(tail -n 6 "$WO")"
send q; exec 9>&-
i=0; while [ "$i" -lt 100 ] && kill -0 "$WP5" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
sum=$(sed -n '/WORK SESSION SUMMARY/,$p' "$WO")
check "shutdown drops a pending automatic action; that server keeps running" 'contains "$sum" "pending automatic stop of PID $L3 dropped: the session ended first" && is_launcher $L3 && is_nserver $C3' "$sum"
check "dev rule: summary records the stop, the protections and the ineffective result" 'contains "$sum" "stopped idle dev server on port 3000" && contains "$sum" "left PID $L2 alone" && contains "$sum" "port 3000 is served again"' "$sum"
check "dev rule: exactly one automatic SIGTERM, never SIGKILL, never a restart" '[ "$(grep -c "automatic SIGTERM" "$TMP/ddata/logs/events.log")" = 1 ] && ! grep -q SIGKILL "$WO" && ! is_launcher $L1' "$(grep ACTION "$TMP/ddata/logs/events.log")"
for p in $L2 $L3 $L4 $L5; do kill -TERM "$p" 2>/dev/null; done

# Limits and measurement logic, checked directly.
out=$(src 'session_init; AUTO_STOP_IDLE_TSSERVER=true; S_MODE=HIGH; S_IDLE_BASE=x; AUTO_MAX_ACTIONS=4; S_AP_N=4; session_auto_schedule $(date +%s)')
check "AUTO_MAX_ACTIONS caps automatic actions per session" 'contains "$out" "AUTO_MAX_ACTIONS (4) reached"' "$out"
out=$(src 'session_init; AUTO_STOP_IDLE_TSSERVER=true; S_MODE=HIGH; S_IDLE_BASE=x; S_AP_N=1; S_AP_LAST=$(( $(date +%s) - 30 )); AUTO_COOLDOWN_MIN=10; session_auto_schedule $(date +%s)')
check "AUTO_COOLDOWN_MIN spaces automatic actions" 'contains "$out" "waiting for the 10-minute cooldown"' "$out"
out=$(src 'session_init; S_MODE=NORMAL; S_IDLE_BASE="ts:1	0	0	ts	1	1"; AUTO_STOP_IDLE_TSSERVER=true; session_auto_schedule $(date +%s); echo "AP=[$S_AP]"')
check "no automatic action without sustained HIGH pressure" 'contains "$out" "AP=[]"' "$out"
out=$(src 'session_init; AUTO_MAX_INEFFECTIVE=2; session_auto_ineffective dev "first"; session_auto_ineffective dev "second"; echo "paused=$S_PAUSE_DEV ts=$S_PAUSE_TS"')
check "a rule pauses itself after repeated ineffective actions (only that rule)" 'contains "$out" "ineffective 1 of 2" && contains "$out" "rule is paused for the rest of the session" && contains "$out" "paused=1 ts=0"' "$out"
out=$(MPM_FAKE_STATE="$WS/empty-fs" src 'session_init; S_AP_WATCH="1|dev|123|1000|1|0|18|40|3999"; FREE_PCT=18; SWAPOUT_RATE=40; session_check_auto_effect; echo "n=$S_INEFF_DEV"')
check "dev stop without measurable pressure improvement counts as ineffective" 'contains "$out" "did not measurably improve" && contains "$out" "n=1"' "$out"
out=$(MPM_FAKE_STATE="$WS/empty-fs" src 'session_init; S_AP_WATCH="1|dev|123|1000|1|0|18|40|3999"; FREE_PCT=26; SWAPOUT_RATE=0; session_check_auto_effect; echo "n=$S_INEFF_DEV"')
check "dev stop followed by real improvement is reported, not counted as failure" 'contains "$out" "free estimate 18% -> 26%" && contains "$out" "n=0"' "$out"
"$TMP/devbin/node" 300 & NV2=$!; disown "$NV2" 2>/dev/null; CHILDREN="$CHILDREN $NV2"; sleep 0.3
out=$(src "auto_terminate dev $NV2 \"\$(proc_identity $NV2)\"; echo rc=\$?")
check "auto_terminate (dev) refuses a process that is not a dev server launcher" 'contains "$out" "no longer a dev server launcher" && contains "$out" "rc=1" && case $(/bin/ps -o args= -p $NV2) in "$TMP/devbin/node "*) true ;; *) false ;; esac' "$out"
kill -KILL "$NV2" 2>/dev/null

TAB=$(printf '\t')
# Dev-server protections, checked directly on a disposable launcher (L6 + server C6) in its own
# project P3. Each case changes one thing; the baseline must be eligible.
P3="$HOME/projects/app"; mkdir -p "$P3/src" "$P3/node_modules/.bin" "$HOME/projects/other"; echo '{}' > "$P3/package.json"; echo x > "$P3/src/page.tsx"
ln -s /bin/bash "$P3/node_modules/.bin/next"
printf 'trap '"'"'kill $c 2>/dev/null; exit 0'"'"' TERM\n"%s" 300 & c=$!\nwait $c\n' "$TMP/devbin/next-server" > "$P3/dev"
age_project() { find "$P3" -type f -exec touch -t 202001010000 {} +; }
age_project
( cd "$P3" && exec "$P3/node_modules/.bin/next" dev ) & L6=$!; disown "$L6" 2>/dev/null; CHILDREN="$CHILDREN $L6"
i=0; C6=""; while [ "$i" -lt 30 ] && [ -z "$C6" ]; do C6=$(pgrep -P "$L6" 2>/dev/null | head -n 1); sleep 0.1; i=$((i + 1)); done; CHILDREN="$CHILDREN $C6"
FS3="$WS/fake-audit"; mkdir -p "$FS3"
base_ps() { cat "$MPM_FIX/ps.txt"; printf '%5s  1101 @UID@  900000   0.0 %s\n%5s %5s @UID@  100000   0.0 next-server (v16.1.1)\n' "$1" "$P3/node_modules/.bin/next" "$C6" "$L6"; }
base_ps "$L6" > "$FS3/ps.txt"
printf '%s\t3010\tLISTEN\n' "$C6" > "$FS3/tcp.tsv"
printf '%s\t%s\n' "$L6" "$P3" > "$FS3/cwd.tsv"
dv() { MPM_FAKE_STATE="$FS3" src "AUTO_DEVSERVER_IDLE_MIN=30; collect_procs fast; dev_verify $L6 '$L6,$C6'"; }
out=$(dv)
check "audit baseline: an idle verified dev server in a quiet project is eligible" 'contains "$out" "OK${TAB}3010${TAB}$P3"' "$out"
echo y > "$P3/src/page.tsx"; out=$(dv)
check "audit: a file edited in the project within the idle period protects it" 'contains "$out" "files in its project changed in the last 30 min"' "$out"
age_project; echo y > "$P3/node_modules/cache.js"; out=$(dv)
check "audit: changes inside node_modules (generated) do not count as activity" 'contains "$out" "OK${TAB}3010"' "$out"
age_project; mkdir -p "$P3/locked"; chmod 000 "$P3/locked"; out=$(dv); chmod 700 "$P3/locked"
check "audit: if recent changes cannot be checked, the server is left alone" 'contains "$out" "recent changes in its project could not be checked"' "$out"
rmdir "$P3/locked"; age_project
# A test runner that runs as "node" (name says nothing), started from a subfolder of the project.
ln -s "$(PATH=/usr/bin:/bin command -v sleep)" "$P3/node_modules/.bin/vitest"
"$P3/node_modules/.bin/vitest" 300 & W1=$!; disown "$W1" 2>/dev/null; CHILDREN="$CHILDREN $W1"; sleep 0.3
{ base_ps "$L6"; printf '%5s  1101 @UID@   80000   0.0 node\n' "$W1"; } > "$FS3/ps.txt"
printf '%s\t%s\n%s\t%s\n' "$L6" "$P3" "$W1" "$P3/src" > "$FS3/cwd.tsv"
out=$(dv)
check "audit: a test runner seen as 'node', in a subfolder of the project, protects it" 'contains "$out" "a build/test is running in the same project (vitest)"' "$out"
printf '%s\t%s\n%s\t%s\n' "$L6" "$P3" "$W1" "$HOME/projects/other" > "$FS3/cwd.tsv"; out=$(dv)
check "audit: a test runner in a different project does not block it" 'contains "$out" "OK${TAB}3010"' "$out"
printf '%s\t%s\n%s\t%s\n' "$L6" "$P3" "$W1" "$HOME/projects/app2" > "$FS3/cwd.tsv"; out=$(dv)
check "audit: a similarly named folder (app2) is not mistaken for the project (app)" 'contains "$out" "OK${TAB}3010"' "$out"
# A build running under the server itself, again seen as "node".
{ base_ps "$L6"; printf '%5s %5s @UID@   80000   0.0 node\n' "$W1" "$C6"; } > "$FS3/ps.txt"
printf '%s\t%s\n' "$L6" "$P3" > "$FS3/cwd.tsv"; out=$(dv)
check "audit: a build/test under the server (grandchild, seen as 'node') protects it" 'contains "$out" "a build/test is running under it"' "$out"
kill -KILL "$W1" 2>/dev/null
# An AI agent that runs as "node .../@anthropic-ai/claude-code/cli.js".
mkdir -p "$TMP/agentbin" "$TMP/agents/@anthropic-ai/claude-code"; ln -s /bin/bash "$TMP/agentbin/node"
printf 'trap '"'"'kill $c 2>/dev/null; exit 0'"'"' TERM\nsleep 300 & c=$!\nwait $c\n' > "$TMP/agents/@anthropic-ai/claude-code/cli.js"
"$TMP/agentbin/node" "$TMP/agents/@anthropic-ai/claude-code/cli.js" & AG=$!; disown "$AG" 2>/dev/null; CHILDREN="$CHILDREN $AG"; sleep 0.3
{ base_ps "$L6"; printf '%5s  1499 @UID@   90000   0.0 node\n' "$AG"; } > "$FS3/ps.txt"
printf '%s\t%s\n%s\t%s\n' "$L6" "$P3" "$AG" "$P3" > "$FS3/cwd.tsv"; out=$(dv)
check "audit: an AI agent (seen as 'node') working in the project protects it" 'contains "$out" "an AI agent is working in this project"' "$out"
printf '%s\t%s\n%s\t%s\n' "$L6" "$P3" "$AG" "$HOME" > "$FS3/cwd.tsv"; out=$(dv)
check "audit: an AI agent working from a folder that contains the project protects it" 'contains "$out" "an AI agent is working in this project"' "$out"
printf '%s\t%s\n%s\t/\n' "$L6" "$P3" "$AG" > "$FS3/cwd.tsv"; out=$(dv)
check "audit: an AI agent working from / is not treated as working in every project" 'contains "$out" "OK${TAB}3010"' "$out"
{ base_ps "$L6" | sed "s/^ *$L6  1101 /$L6 $AG /"; printf '%5s  1499 @UID@   90000   0.0 node\n' "$AG"; } > "$FS3/ps.txt"
printf '%s\t%s\n%s\t/\n' "$L6" "$P3" "$AG" > "$FS3/cwd.tsv"; out=$(dv)
check "audit: a server started by an AI agent seen as 'node' (claude-code) is protected" 'contains "$out" "it was started by an AI agent (claude-code)"' "$out"
kill -TERM "$AG" 2>/dev/null
# Activity anywhere in the server's tree (here a busy grandchild) resets its idle time.
base_ps "$L6" > "$FS3/ps.txt"
/usr/bin/yes > /dev/null & BZ=$!; disown "$BZ" 2>/dev/null
{ base_ps "$L6"; printf '%5s %5s @UID@    1000   0.0 yes\n' "$BZ" "$C6"; } > "$FS3/ps.txt"
out=$(MPM_FAKE_STATE="$FS3" src 'AUTO_STOP_IDLE_DEVSERVER=true; AUTO_STOP_IDLE_TSSERVER=false; collect_procs fast; session_init; t0=$(( $(date +%s) - 10 )); session_track_idle $t0; sleep 3; session_track_idle $(date +%s); echo "T0=$t0"; printf "%s\n" "$S_IDLE_BASE"')
t0=$(printf '%s\n' "$out" | sed -n 's/^T0=//p')
out=$(printf '%s\n' "$out" | awk -F'\t' -v k="dev:$L6" -v t0="$t0" '$1 == k { print ($3 > t0 ? "RESET" : "STILL-IDLE"), $6 }')
kill -KILL "$BZ" 2>/dev/null
check "audit: CPU of a grandchild counts; a busy tree is not idle" 'contains "$out" "RESET" && contains "$out" ",$BZ"' "$out"
out=$(src "path_related /a/web /a/web/src && path_related /a /a/web && ! path_related /a/web /a/web2 && ! path_related /a/web /b/web && echo PATHS_OK")
check "audit: same-project matching is by folder containment, not name prefix" 'contains "$out" PATHS_OK' "$out"
kill -TERM "$L6" 2>/dev/null

# Manager-owned temporary files: only stale .times.PID / history.tsv.tmp.PID in state/.
SD="$TMP/data/state"; mkdir -p "$SD/sub" "$WS/elsewhere"
ln -s "$(PATH=/usr/bin:/bin command -v sleep)" "$TMP/mac-performance-manager-live"
"$TMP/mac-performance-manager-live" 300 & LIVE=$!; disown "$LIVE" 2>/dev/null; CHILDREN="$CHILDREN $LIVE"; sleep 0.3
for f in .times.999999 history.tsv.tmp.999998 ".times.$LIVE" .times.abc notes.txt sub/.times.999995; do echo x > "$SD/$f"; touch -t 202001010000 "$SD/$f"; done
echo x > "$SD/.times.999997"
echo keep > "$WS/elsewhere/target"; ln -s "$WS/elsewhere/target" "$SD/.times.999996"; touch -h -t 202001010000 "$SD/.times.999996"
out=$(src 'AUTO_CLEAN_MANAGER_TEMP=false; session_init; session_clean_temp; echo "[$S_AUTO]"')
check "manager temp cleanup is off unless enabled" '[ -e "$SD/.times.999999" ] && contains "$out" "[]"' "$out"
out=$(src 'AUTO_CLEAN_MANAGER_TEMP=true; session_init; session_clean_temp; printf "%s\n" "$S_AUTO"')
check "manager temp cleanup removes only stale files of finished manager runs" '[ ! -e "$SD/.times.999999" ] && [ ! -e "$SD/history.tsv.tmp.999998" ] && contains "$out" "removed 2 stale temporary file(s)"' "$out$(ls -la "$SD")"
check "...and keeps: a live manager's file, recent files, symlinks (and their target), other names, subfolders" '[ -e "$SD/.times.$LIVE" ] && [ -e "$SD/.times.999997" ] && [ -L "$SD/.times.999996" ] && [ "$(cat "$WS/elsewhere/target")" = keep ] && [ -e "$SD/.times.abc" ] && [ -e "$SD/notes.txt" ] && [ -e "$SD/sub/.times.999995" ]' "$(ls -la "$SD" "$SD/sub")"
kill -KILL "$LIVE" 2>/dev/null

out=$(src 'session_init; i=0; while [ $i -lt 60 ]; do session_note AUTO "event $i"; i=$((i + 1)); done; printf "%s\n" "$S_AUTO" | wc -l | tr -d " "; printf "%s\n" "$S_AUTO" | tail -n 1')
check "session history is bounded (40 entries, newest kept)" 'contains "$out" "40" && contains "$out" "event 59"' "$out"
out=$(src 'sleep 30 & SLEEP_PID=$!; p=$!; kill_own_helpers; sleep 0.3; kill -0 $p 2>/dev/null && echo ALIVE || echo GONE')
check "own helper process is stopped on exit" 'contains "$out" GONE' "$out"
"$TMP/devbin/node" 300 & HV=$!; disown "$HV" 2>/dev/null; CHILDREN="$CHILDREN $HV"; sleep 0.3
out=$(src "SLEEP_PID=$HV; kill_own_helpers; echo done")
check "a process the manager did not start is never stopped as a helper" 'case $(/bin/ps -o args= -p "$HV" 2>/dev/null) in "$TMP/devbin/node "*) true ;; *) false ;; esac' "$out"
kill -KILL "$HV" 2>/dev/null

# ---------------------------------------------------------------------------
echo "[safety: processes]"
# All process lookups below use the real ps (fixture PIDs are not real processes).
export MPM_REAL_PS=1
VICTIM_BIN="$TMP/victim-sleep"
ln -s "$(PATH=/usr/bin:/bin command -v sleep)" "$VICTIM_BIN"
cp_dummy="$TMP/mac-performance-manager-dummy"; ln -s "$(PATH=/usr/bin:/bin command -v sleep)" "$cp_dummy"

is_proc() {   # pid binary -> 0 while that PID is still the test process started from binary
  case $(/bin/ps -o args= -p "$1" 2>/dev/null) in "$2 "*) return 0 ;; esac; return 1
}
alive() { is_proc "$1" "$VICTIM_BIN"; }
# start_victim [ignore_term] -> VPID; returns 1 if the process did not come up.
start_victim() {
  local bin=${2:-$VICTIM_BIN} i=0
  if [ "${1:-}" = ignore_term ]; then ( trap '' TERM; exec "$bin" 300 ) & else "$bin" 300 & fi
  VPID=$!; disown "$VPID" 2>/dev/null; CHILDREN="$CHILDREN $VPID"
  while [ "$i" -lt 30 ]; do is_proc "$VPID" "$bin" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
gone() { local i=0; while [ "$i" -lt 30 ]; do alive "$1" || return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
inject() { export MPM_FAKE_PS_PID=$1 MPM_FAKE_PS_MODE=$2; rm -f "$MPM_FAKE_STATE/ps_ident_count"; }
uninject() { unset MPM_FAKE_PS_PID MPM_FAKE_PS_MODE; }

if ! start_victim; then
  bad "disposable test process could not be started; process safety tests cannot run" "$(ls -l "$VICTIM_BIN")"
else
  V1=$VPID
  out=$(src "check_terminable $V1 && echo TERMINABLE; echo \"comm=\$T_COMM\"")
  check "identity of a disposable process is verified (check_terminable)" 'contains "$out" TERMINABLE && contains "$out" "comm=$VICTIM_BIN"' "$out"
  out=$(printf 'no\n' | src "terminate_flow $V1")
  check "terminate: anything but 'yes' cancels" 'alive $V1 && contains "$out" "Cancelled. Nothing was sent."' "$out"
  out=$(printf '\n' | src "terminate_flow $V1")
  check "terminate: empty answer cancels" 'alive $V1 && contains "$out" "Cancelled"' "$out"
  out=$(src "terminate_flow $V1" </dev/null)
  check "terminate: EOF at the prompt sends nothing" 'alive $V1 && ! contains "$out" "exited"' "$out"
  out=$(printf 'y\n' | src "terminate_flow $V1")
  check "terminate: 'y' is not enough" 'alive $V1 && contains "$out" "Cancelled"' "$out"
  check "terminate: shows name, PID, CPU, memory, command first" 'contains "$out" "Name:" && contains "$out" "PID:      $V1" && contains "$out" "CPU:" && contains "$out" "Memory:" && contains "$out" "Command:"' "$out"
  out=$(printf 'yes\n' | src "KILL_GRACE_SEC=3; terminate_flow $V1")
  check "terminate: typed 'yes' sends SIGTERM and the process exits" 'gone $V1 && contains "$out" "exited" && ! contains "$out" "SIGKILL"' "$out"
fi

# A process that ignores SIGTERM: SIGKILL needs a second, different typed word.
if start_victim ignore_term; then
  V3=$VPID
  out=$(printf 'yes\nyes\n' | src "KILL_GRACE_SEC=1; terminate_flow $V3")
  check "SIGTERM-ignoring process: reported as still running" 'alive $V3 && contains "$out" "still running"' "$out"
  check "SIGTERM-ignoring process is NOT force-killed without typing KILL" 'alive $V3 && contains "$out" "Left running"' "$out"
  out=$(printf 'yes\n' | src "KILL_GRACE_SEC=1; terminate_flow $V3")
  check "EOF at the SIGKILL prompt sends nothing" 'alive $V3 && ! contains "$out" "SIGKILL sent"' "$out"
  out=$(printf 'yes\nkill\n' | src "KILL_GRACE_SEC=1; terminate_flow $V3")
  check "lowercase 'kill' is not confirmation" 'alive $V3 && contains "$out" "Left running"' "$out"
  out=$(printf 'yes\nKILL\n' | src "KILL_GRACE_SEC=1; terminate_flow $V3")
  check "SIGKILL only after typing KILL" 'gone $V3 && contains "$out" "SIGKILL sent"' "$out"
else
  bad "SIGTERM-ignoring test process could not be started"
fi

out=$(src 'terminate_flow 1')
check "refuses PID 1" 'contains "$out" "Refused" && contains "$out" "core system process"' "$out"
out=$(src 'terminate_flow $$')
check "refuses the manager's own process" 'contains "$out" "Refused" && contains "$out" "this manager"' "$out"
out=$(src 'terminate_flow $PPID')
check "refuses the parent shell/terminal" 'contains "$out" "Refused" && contains "$out" "this manager or the shell"' "$out"
out=$(src 'terminate_flow abc')
check "refuses non-numeric input" 'contains "$out" "not a PID"' "$out"
out=$(src 'terminate_flow 999999')
check "refuses nonexistent PID" 'contains "$out" "No process"' "$out"

if start_victim "" "$cp_dummy"; then
  V2=$VPID
  out=$(printf 'yes\n' | src "terminate_flow $V2")
  check "refuses another manager instance" 'is_proc $V2 "$cp_dummy" && contains "$out" "Mac Performance Manager instance"' "$out"
  kill -KILL "$V2" 2>/dev/null
else
  bad "dummy manager test process could not be started"
fi

# Faults injected by the ps stub, each on its own fresh disposable process. Every answer
# is 'yes' (and 'KILL'), so a guard that failed open would signal it and it would be gone.
fault() {   # mode expected_text description [ignore_term] [input]
  if ! start_victim "${4:-}"; then bad "$3 (test process could not be started)"; return; fi
  local v=$VPID want=$2
  inject "$v" "$1"; out=$(printf "${5:-yes\n}" | src "KILL_GRACE_SEC=1; terminate_flow $v"); uninject
  check "$3" 'alive $v && contains "$out" "$want" && ! contains "$out" "SIGKILL sent" && ! contains "$out" "exited."' "$out"
  kill -KILL "$v" 2>/dev/null
}
fault uid0 "belongs to another user" "refuses processes of other users/system (uid check)"
fault syspath "part of macOS" "refuses macOS executables (/System, /usr/libexec, ...)"
fault protname "critical for your session" "refuses critical session processes by name"
fault garbled "cannot be identified" "refuses when ps output cannot be parsed (identity unverifiable)"
fault noident "cannot be identified" "refuses when the start time/identity cannot be read"
fault reuse:1 "changed or exited since review" "PID reused between review and 'yes': nothing sent"
# identity reads: review, before SIGTERM, one wait-loop check (grace 1 s), before SIGKILL
fault reuse:3 "already exited or changed; nothing sent" "PID reused before SIGKILL confirmation: nothing sent" ignore_term 'yes\nKILL\n'
out=$(src 'is_protected_name WindowServer && is_protected_name Finder && is_protected_name loginwindow && ! is_protected_name node && echo PROT_OK')
check "critical session processes are protected by name" 'contains "$out" PROT_OK' "$out"
unset MPM_REAL_PS

# ---------------------------------------------------------------------------
echo "[safety: disk]"
# Sizes are distinct so the scan's size ranking is deterministic whatever order find
# returns: plain/node_modules (3 MB) > repo/node_modules (2 MB) > repo/dist (1 MB) > rest.
P="$HOME/proj"; mkdir -p "$P/plain/node_modules/a" "$P/repo/dist" "$P/repo/build" "$P/repo/node_modules/b" "$P/plain/.venv" "$P/repo/committed_nm/node_modules"
head -c 3145728 /dev/urandom > "$P/plain/node_modules/a/blob"
head -c 2097152 /dev/urandom > "$P/repo/node_modules/b/blob"
head -c 1048576 /dev/urandom > "$P/repo/dist/out.js"
echo x > "$P/repo/build/keep.js"; echo x > "$P/repo/committed_nm/node_modules/f.js"; echo x > "$P/plain/.venv/pyvenv.cfg"
ln -s "$P/plain/node_modules" "$P/plain/link_nm"
if command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1; then
  ( cd "$P/repo" && git init -q && printf 'dist/\nnode_modules/\n' > .gitignore && git add .gitignore build && git add -f committed_nm &&
    git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
  e() { src "artifact_eligible '$1' '$P' && echo ELIGIBLE"; }
  check "node_modules outside git: eligible" 'contains "$(e "$P/plain/node_modules")" ELIGIBLE'
  check "git-ignored node_modules: eligible" 'contains "$(e "$P/repo/node_modules")" ELIGIBLE'
  check "git-ignored dist: eligible" 'contains "$(e "$P/repo/dist")" ELIGIBLE'
  check "tracked build/: refused" 'contains "$(e "$P/repo/build")" "tracked by Git"'
  check "committed node_modules: refused" 'contains "$(e "$P/repo/committed_nm/node_modules")" "tracked by Git"'
  check ".venv outside a repo: report only" 'contains "$(e "$P/plain/.venv")" "report only"'
  check "symlink: refused" 'contains "$(e "$P/plain/link_nm")" "symbolic link"'
  check "path outside scanned folder: refused" 'contains "$(e "$TMP/data")" "outside"'

  # Each refused artifact, fed straight into the Trash flow with 'trash' typed: it must not
  # move. SCAN_RESULTS is built here, so this does not depend on find's traversal order.
  for t in "$P/repo/build" "$P/repo/committed_nm/node_modules" "$P/plain/.venv" "$P/plain/link_nm" "$TMP/data"; do
    out=$(printf '1\ntrash\n' | src "SCAN_ROOT='$P'; SCAN_RESULTS=\$(printf '8\t%s' '$t'); trash_artifact_flow")
    check "Trash flow refuses ${t#"$TMP"/} even when 'trash' is typed" '[ -e "$t" ] && contains "$out" "Not offered" && ! contains "$out" "Moved to Trash"' "$out"
  done
  check "refused items: Trash untouched" '[ -z "$(ls -A "$HOME/.Trash")" ]' "$(ls -A "$HOME/.Trash")"

  out=$(printf '4\n2\n%s\nb\n13\n' "$P" | mpm 2>&1)
  listing=$(printf '%s\n' "$out" | awk '/LARGEST ARTIFACTS/ { f = 1; next } f && /^ +[0-9]+\) / { print $NF } f && /Total listed/ { exit }')
  first3=$(printf '%s\n' "$listing" | head -n 3 | tr '\n' ' ')
  check "scan ranks artifacts by size, deterministically" '[ "$first3" = "~/proj/plain/node_modules ~/proj/repo/node_modules ~/proj/repo/dist " ]' "$listing"
  check "scan lists every artifact once and never the symlink" '[ "$(printf "%s\n" "$listing" | grep -c .)" = 6 ] && ! contains "$listing" link_nm' "$listing"

  out=$(printf '4\n2\n%s\n3\n1\nnope\nb\n13\n' "$P" | mpm 2>&1)
  check "Trash move cancelled unless 'trash' is typed" '[ -d "$P/repo/node_modules" ] && [ -d "$P/plain/node_modules" ] && contains "$out" "Cancelled. Nothing changed." && [ -z "$(ls -A "$HOME/.Trash")" ]' "$(printf '%s\n' "$out" | grep -A8 REVIEW)"
  out=$(printf '4\n2\n%s\n3\n1\ntrash\nb\n13\n' "$P" | mpm 2>&1)
  review=$(printf '%s\n' "$out" | grep -A1 REVIEW | grep 'Path:')
  check "the reviewed entry is the one selected (plain/node_modules)" 'contains "$review" "/proj/plain/node_modules" && ! contains "$review" "/repo/"' "$review"
  check "confirmed artifact goes to Trash, not deleted" '[ ! -e "$P/plain/node_modules" ] && [ -d "$P/repo/node_modules" ] && [ "$(ls "$HOME/.Trash" | grep -c "^node_modules-mpm-")" = 1 ] && [ -f "$HOME/.Trash/$(ls "$HOME/.Trash" | grep "^node_modules-mpm-")/a/blob" ]' "$(printf '%s\n' "$out" | grep -A8 REVIEW; ls -la "$HOME/.Trash")"
  check "Finder was never really asked to delete anything (stubbed)" '[ -f "$MPM_FAKE_STATE/osascript.calls" ]'
  check "scan never touched source files" '[ -f "$P/repo/build/keep.js" ] && [ -f "$P/repo/committed_nm/node_modules/f.js" ] && [ -f "$P/repo/dist/out.js" ] && [ -f "$P/plain/.venv/pyvenv.cfg" ] && [ -L "$P/plain/link_nm" ]'

  # The folder is swapped AFTER review (once the 'trash' prompt is shown) and BEFORE 'trash'
  # is typed. The flow must re-check after confirmation and move nothing.
  race() {   # swap_command
    local R="$HOME/race" fifo="$TMP/race.fifo" o="$TMP/race.out" sp i=0
    case $R in "$TMP"/*) rm -rf -- "$R" ;; esac
    mkdir -p "$R/app/node_modules/x" "$R/keep"; echo k > "$R/keep/data"; echo m > "$R/app/node_modules/x/m"
    rm -f "$fifo" "$o"; mkfifo "$fifo"
    src "SCAN_ROOT='$R'; SCAN_RESULTS=\$(printf '8\t%s' '$R/app/node_modules'); trash_artifact_flow" < "$fifo" > "$o" &
    sp=$!
    exec 8>"$fifo"; printf '1\n' >&8
    while [ "$i" -lt 100 ] && ! grep -q "Type 'trash'" "$o" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
    eval "$1"
    printf 'trash\n' >&8; exec 8>&-
    wait "$sp"; out=$(cat "$o")
  }
  trash_before=$(ls -A "$HOME/.Trash" | wc -l | tr -d ' ')
  R="$HOME/race"
  race 'mv "$R/app/node_modules" "$R/app/nm_orig"; ln -s "$R/keep" "$R/app/node_modules"'
  check "Trash: folder replaced by a symlink after review is refused" '[ -f "$R/keep/data" ] && [ -L "$R/app/node_modules" ] && [ -f "$R/app/nm_orig/x/m" ] && contains "$out" "symbolic link since review" && [ "$(ls -A "$HOME/.Trash" | wc -l | tr -d " ")" = "$trash_before" ]' "$out"
  race 'mv "$R/app/node_modules" "$R/app/nm_orig"; mkdir "$R/app/node_modules"'
  check "Trash: folder replaced by another folder after review is refused" '[ -d "$R/app/node_modules" ] && [ -f "$R/app/nm_orig/x/m" ] && contains "$out" "changed since review" && [ "$(ls -A "$HOME/.Trash" | wc -l | tr -d " ")" = "$trash_before" ]' "$out"
  race ':'
  check "Trash: unchanged folder is still moved after the re-check (control)" '[ ! -e "$R/app/node_modules" ] && contains "$out" "Moved to Trash" && [ "$(ls -A "$HOME/.Trash" | wc -l | tr -d " ")" = $((trash_before + 1)) ]' "$out"
else
  skip "git-based disk safety tests" "git not usable"
fi

# ---------------------------------------------------------------------------
echo "[data folder]"
printf 'NOTIFICATIONS_ENABLED=false\nCOLOR=never\n' > "$TMP/nodata.env"
FALLBACK="$HOME/Library/Application Support/mac-performance-manager"
RW="$TMP/rw"; mkdir -p "$RW"; cp "$SCRIPT" "$RW/mpm.sh"
out=$(PATH="$STUBS:$PATH" "$SH" "$RW/mpm.sh" --report --config "$TMP/nodata.env" 2>&1); rc=$?
check "writable script folder: data stays next to the script (default unchanged)" '[ $rc = 0 ] && ls "$RW"/reports/report-*.txt >/dev/null 2>&1 && [ ! -e "$FALLBACK" ]' "$out"
if [ "$(id -u)" = 0 ]; then
  skip "read-only script folder" "running as root, every folder is writable"
else
  RO="$TMP/ro"; mkdir -p "$RO"; cp "$SCRIPT" "$RO/mpm.sh"; chmod 555 "$RO"
  out=$(PATH="$STUBS:$PATH" "$SH" "$RO/mpm.sh" --report --config "$TMP/nodata.env" 2>&1); rc=$?
  check "read-only script folder: data goes to ~/Library/Application Support, no warning" '[ $rc = 0 ] && ls "$FALLBACK"/reports/report-*.txt >/dev/null 2>&1 && [ -d "$FALLBACK/state" ] && ! contains "$out" "cannot write" && [ "$(ls -A "$RO")" = mpm.sh ]' "$out"
  printf 'DATA_DIR=%s\nNOTIFICATIONS_ENABLED=false\nCOLOR=never\n' "$RO/data" > "$TMP/rodata.env"
  out=$(PATH="$STUBS:$PATH" "$SH" "$RO/mpm.sh" --once --config "$TMP/rodata.env" 2>&1); rc=$?
  check "DATA_DIR set but not writable: warned, never silently replaced" '[ $rc = 0 ] && contains "$out" "cannot write to $RO/data"' "$out"
  chmod 755 "$RO"
fi

# ---------------------------------------------------------------------------
echo "[install]"
INST="$ROOT/install.sh"
L="$HOME/.local/bin/mpm"; SHARE="$HOME/.local/share/mac-performance-manager"
SYSPATH="/usr/bin:/bin:/usr/sbin:/sbin"
check "installer syntax (bash -n)" '"$SH" -n "$INST"'
out=$(grep -nE '(^|[;&|[:space:]])sudo[[:space:]]|rm -rf|zshrc|bash_profile|\.profile' "$INST" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'say ')
check "installer: no sudo, no rm -rf, never writes a shell profile" '[ -z "$out" ]' "$out"

out=$(PATH="$SYSPATH" "$SH" "$INST" 2>&1); rc=$?
check "clone install: mpm links to the clone and runs" '[ $rc = 0 ] && [ "$(readlink "$L")" = "$SCRIPT" ] && "$L" --version | grep -q "mac-performance-manager 1." && contains "$out" "Installed: mac-performance-manager"' "$out"
check "clone install: PATH hint printed, shell profile untouched" 'contains "$out" "is not in your PATH yet" && contains "$out" "export PATH=\"\$HOME/.local/bin:\$PATH\"" && [ ! -e "$HOME/.zshrc" ]' "$out"
out=$(PATH="$HOME/.local/bin:$SYSPATH" "$SH" "$INST" 2>&1); rc=$?
check "re-running the installer is harmless; no PATH hint once on PATH" '[ $rc = 0 ] && [ "$(readlink "$L")" = "$SCRIPT" ] && ! contains "$out" "not in your PATH"' "$out"

rm -f "$L"; printf '#!/bin/sh\necho other\n' > "$L"; chmod +x "$L"
out=$(PATH="$SYSPATH" "$SH" "$INST" 2>&1); rc=$?
check "an unrelated ~/.local/bin/mpm is never replaced" '[ $rc = 1 ] && [ ! -L "$L" ] && grep -q "echo other" "$L" && contains "$out" "left alone"' "$out"
out=$(PATH="$SYSPATH" "$SH" "$INST" --uninstall 2>&1); rc=$?
check "uninstall leaves an unrelated mpm alone" '[ $rc = 0 ] && grep -q "echo other" "$L" && contains "$out" "not Mac Performance Manager"' "$out"
rm -f "$L"

# One-command install: the installer is piped into bash and downloads from MPM_INSTALL_URL
# (a local file:// copy here; the tests never use the network).
RAW="$TMP/raw"; mkdir -p "$RAW"; cp "$SCRIPT" "$ROOT/config.env.example" "$RAW/"
out=$(cd "$TMP" && MPM_INSTALL_URL="file://$RAW" PATH="$SYSPATH" "$SH" < "$INST" 2>&1); rc=$?
check "one-command install (piped): script downloaded, linked, runs" '[ $rc = 0 ] && [ "$(readlink "$L")" = "$SHARE/mac-performance-manager.sh" ] && [ -x "$SHARE/mac-performance-manager.sh" ] && [ -f "$SHARE/config.env.example" ] && "$L" --version | grep -q "mac-performance-manager 1."' "$out"
perms=$(ls -ld "$SHARE" | cut -c1-10)
check "install folder is private (drwx------)" '[ "$perms" = drwx------ ]' "$perms"
PATH="$STUBS:$PATH" "$L" --once --no-color > /dev/null 2>&1
check "downloaded install keeps its data in its own folder" '[ -d "$SHARE/state" ] && [ -d "$SHARE/logs" ]'
sum0=$(cksum < "$SHARE/mac-performance-manager.sh")
BAD="$TMP/rawbad"; mkdir -p "$BAD"; echo '<html>404 Not Found</html>' > "$BAD/mac-performance-manager.sh"
out=$(MPM_INSTALL_URL="file://$BAD" PATH="$SYSPATH" "$SH" < "$INST" 2>&1); rc=$?
check "invalid download rejected; installed copy unchanged" '[ $rc = 1 ] && contains "$out" "not a valid" && [ "$(cksum < "$SHARE/mac-performance-manager.sh")" = "$sum0" ] && ! ls -A "$SHARE" | grep -q download' "$out"
out=$(MPM_INSTALL_URL="file://$TMP/nowhere" PATH="$SYSPATH" "$SH" < "$INST" 2>&1); rc=$?
check "failed download changes nothing" '[ $rc = 1 ] && contains "$out" "download failed" && [ "$(cksum < "$SHARE/mac-performance-manager.sh")" = "$sum0" ] && [ "$(readlink "$L")" = "$SHARE/mac-performance-manager.sh" ]' "$out"

printf 'NOTIFICATIONS_ENABLED=false\nCOLOR=never\n' > "$SHARE/config.env"
PATH="$STUBS:$PATH" "$L" --work > "$TMP/inst-work.out" 2>&1 < /dev/null &
IW=$!; CHILDREN="$CHILDREN $IW"
i=0; while [ "$i" -lt 50 ] && [ ! -s "$SHARE/state/work.pid" ]; do sleep 0.1; i=$((i + 1)); done
out=$(PATH="$SYSPATH" "$SH" "$INST" --uninstall 2>&1); rc=$?
check "uninstall refuses while a work mode runs from the install folder" '[ $rc = 1 ] && contains "$out" "mpm --stop" && [ -L "$L" ] && [ -f "$SHARE/mac-performance-manager.sh" ]' "$out"
PATH="$STUBS:$PATH" "$L" --stop < /dev/null > /dev/null 2>&1
i=0; while [ "$i" -lt 50 ] && kill -0 "$IW" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
out=$(PATH="$SYSPATH" "$SH" -s -- --uninstall < "$INST" 2>&1); rc=$?
gone=$(ls "$HOME/.Trash" | grep '^mac-performance-manager-removed-' | head -n 1)
check "uninstall: command removed, install folder moved to the Trash (recoverable)" '[ $rc = 0 ] && [ ! -L "$L" ] && [ ! -e "$SHARE" ] && [ -n "$gone" ] && [ -f "$HOME/.Trash/$gone/mac-performance-manager.sh" ] && [ -d "$HOME/.Trash/$gone/state" ]' "$out"
PATH="$SYSPATH" "$SH" "$INST" > /dev/null 2>&1
out=$(PATH="$SYSPATH" "$SH" "$INST" --uninstall 2>&1); rc=$?
check "uninstall of a clone install: link removed, clone untouched" '[ $rc = 0 ] && [ ! -L "$L" ] && [ -f "$SCRIPT" ] && [ -f "$INST" ] && contains "$out" "was not touched"' "$out"
# Printed commands must work when pasted, even from a clone whose path has spaces and quotes.
ODD="$HOME/My Clone's \"copy\""; mkdir -p "$ODD"; cp "$INST" "$SCRIPT" "$ROOT/config.env.example" "$ODD/"
out=$(PATH="$SYSPATH" "$SH" "$ODD/install.sh" 2>&1); rc=$?
cmd=$(printf '%s\n' "$out" | sed -n 's/^  settings  optional:  //p')
(cd "$TMP" && eval "$cmd") > /dev/null 2>&1
check "printed settings command works when pasted (path with spaces and quotes)" '[ $rc = 0 ] && [ -n "$cmd" ] && [ -f "$ODD/config.env" ] && [ "$(readlink "$L")" = "$ODD/mac-performance-manager.sh" ]' "$out"
echo "MY_OWN_SETTINGS" > "$ODD/config.env"
(cd "$TMP" && eval "$cmd") > /dev/null 2>&1
out=$(PATH="$SYSPATH" "$SH" "$ODD/install.sh" 2>&1)
check "an existing config.env is never overwritten, not even by the printed command" 'grep -q MY_OWN_SETTINGS "$ODD/config.env" && contains "$out" "yours, kept as is" && ! contains "$out" "cp -n"' "$out"
pathcmd=$(printf '%s\n' "$out" | sed -n "s/^  echo '\(export PATH=.*\)' >> .*/\1/p")
got=$(PATH="$SYSPATH" "$SH" -c "$pathcmd"' && printf "%s" "${PATH%%:*}"')
check "printed PATH line adds ~/.local/bin" '[ "$got" = "$HOME/.local/bin" ]' "cmd: $pathcmd -> $got"
PATH="$SYSPATH" "$SH" "$ODD/install.sh" --uninstall > /dev/null 2>&1
out=$(PATH="$SYSPATH" "$SH" "$INST" --uninstall 2>&1); rc=$?
check "uninstall when nothing is installed" '[ $rc = 0 ] && contains "$out" "Nothing to remove"' "$out"

# ---------------------------------------------------------------------------
echo "[compatibility]"
if command -v original-awk >/dev/null 2>&1; then
  BWK="$TMP/bwk"; mkdir -p "$BWK"; ln -s "$(command -v original-awk)" "$BWK/awk"
  a=$(mpm --once 2>&1 | grep -v -E '^Mac Performance Manager|^Mac Perf' | sed 's/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]//g')
  b=$(PATH="$STUBS:$BWK:$PATH" "$SH" "$SCRIPT" --config "$CFG" --once 2>&1 | grep -v -E '^Mac Performance Manager|^Mac Perf' | sed 's/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]//g')
  check "identical output with BWK awk (the macOS awk family)" '[ "$a" = "$b" ]' "$(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -n 20)"
else
  skip "BWK awk comparison" "original-awk not installed (on macOS, /usr/bin/awk already is BWK awk)"
fi

echo
printf 'Passed: %d   Failed: %d   Skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
