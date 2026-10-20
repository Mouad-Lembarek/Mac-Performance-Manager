#!/bin/bash
# =============================================================================
# mac-performance-manager.sh
#
# A lightweight, safe performance manager for macOS (Apple Silicon first).
#
# Design rules
#   * Native macOS tools only (vm_stat, sysctl, ps, top, df, pmset, lsof).
#   * No network access, no telemetry, no sudo, no background daemons.
#   * Never kills, quits, or deletes anything of yours without an explicit typed
#     confirmation from you. Never deletes permanently (moves to Trash).
#     Sole exception, OFF by default: the opt-in AUTO_STOP_IDLE_* rules may send
#     SIGTERM (never SIGKILL) to an idle TypeScript server / dev server during a
#     work session, under sustained pressure, after a notice you can cancel (x).
#   * Compatible with macOS /bin/bash 3.2 and the BSD userland.
#
# Usage: ./mac-performance-manager.sh [--help|--work|--report|--live|--once|--free|--stop]
# =============================================================================

# shellcheck disable=SC2088,SC2034,SC2120
set -u
export LC_ALL=C          # stable number formats (12.5, not 12,5) for parsing
umask 077                # logs/reports readable only by you

MPM_VERSION="1.0.0"
TAB=$(printf '\t')
NL='
'

for _d in /usr/bin /bin /usr/sbin /sbin; do
  case ":$PATH:" in *":$_d:"*) ;; *) PATH="$PATH:$_d" ;; esac
done
export PATH

# Resolve the directory of this script (macOS has no `readlink -f` before 12.3).
_mpm_src="${BASH_SOURCE[0]}"
while [ -h "$_mpm_src" ]; do
  _mpm_dir=$(cd -P "$(dirname "$_mpm_src")" && pwd)
  _mpm_src=$(readlink "$_mpm_src")
  case "$_mpm_src" in /*) ;; *) _mpm_src="$_mpm_dir/$_mpm_src" ;; esac
done
SCRIPT_DIR=$(cd -P "$(dirname "$_mpm_src")" && pwd)

# =============================================================================
# Globals
# =============================================================================
init_globals() {
  EXITING=0; WORK_ACTIVE=0; STOP_REQUESTED=0; SLEEP_PID=""; LIVE_ACTIVE=0
  SAVED_STTY=""; OWN_PIDFILE=0; WORK_LOCK_HELD=0; DIRS_OK=0; FORCE_NO_COLOR=0
  CONFIG_FILE=""; CONFIG_WARNINGS=""; CONFIG_STATUS="defaults"
  OS_NAME=""; ARCH=""; MACOS_VERSION=""; MACOS_BUILD=""; HW_MODEL=""; MODEL_NAME=""
  CPU_BRAND=""; NCPU=1; PCORES=""; ECORES=""; TRANSLATED=0; CURRENT_UID=""
  MEM_TOTAL_MB=0; PAGE_SIZE=16384
  MEM_OK=0; VM_PS=0; VM_FREE=0; VM_ACTIVE=0; VM_INACTIVE=0; VM_SPEC=0; VM_THROTTLED=0
  VM_WIRED=0; VM_PURGEABLE=0; VM_FILEBACKED=0; VM_ANON=0; VM_STORED=0; VM_OCCUPIED=0
  VM_PAGEINS=0; VM_PAGEOUTS=0; VM_SWAPINS=0; VM_SWAPOUTS=0
  MEM_APP_MB=0; MEM_WIRED_MB=0; MEM_COMP_MB=0; MEM_STORED_MB=0; MEM_CACHED_MB=0
  MEM_USED_MB=0; MEM_FREE_MB=0; MEM_AVAIL_EST_MB=""; COMP_RATIO_X10=0
  PRESS_LEVEL=""; FREE_PCT=""; PRESS_SOURCE=""
  SWAP_OK=0; SWAP_TOTAL_MB=0; SWAP_USED_MB=0; SWAP_FREE_MB=0
  DISK_OK=0; DISK_TARGET="/"; DISK_TOTAL_MB=0; DISK_AVAIL_MB=0; DISK_USED_PCT=0; DISK_STATE="UNKNOWN"
  BATT_SRC=""; BATT_PCT=""; BATT_STATE=""; UPTIME_SEC=""; LOAD1=""; LOAD5=""; LOAD15=""
  PROCS=""; PROC_MEM_SRC="RSS"; CPU_SRC="ps"; CPU_USER=""; CPU_SYS=""; CPU_IDLE=""; CPU_TOTAL_PCT=0
  SUM_CPU=0; SUM_NPROCS=0; SUM_CUR_N=0; SUM_CUR_MEM=0; SUM_CUR_REND=0; SUM_CUR_PLUG=0; SUM_CUR_MAIN=0
  SUM_NODE_N=0; SUM_NODE_MEM=0; SUM_PY_N=0; SUM_PY_MEM=0; SUM_BRAVE_N=0; SUM_BRAVE_MEM=0
  SUM_DOCK_N=0; SUM_DOCK_MEM=0; SUM_AI_N=0; SUM_AI_MEM=0
  SCAN_RESULTS=""; SCAN_ROOT=""; SCAN_ABORT=0
  HAVE_TOP=0; HAVE_PMSET=0; HAVE_LSOF=0; HAVE_OSASCRIPT=0; HAVE_MP=0; HAVE_SP=0; HAVE_DOCKER=0; HAVE_GIT=0; HAVE_DU=0; HAVE_FIND=0
  LOG_DIR=""; REPORT_DIR=""; STATE_DIR=""; EVENT_LOG=""; HISTORY_FILE=""; PIDFILE=""
  C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_YEL=""; C_GRN=""; C_CYN=""
  T_UID=""; T_PPID=""; T_RSS=""; T_CPU=""; T_ETIME=""; T_COMM=""; T_REASON=""; T_ACTION=""; QA_ACTION=""; QA_NAME=""
  S_INPUT=none; S_CPU_MS=""
  CLEAN_BASE_SET=0
  LAST_NOTIFY_TS=0; LAST_SWAPWARN_TS=0; LAST_RECO_TS=0
  init_monitor_state
}

init_monitor_state() {
  PREV_TS=""; PREV_SWAPOUTS=""; PREV_SWAPINS=""; SWAPOUT_RATE=""; SWAPIN_RATE=""
  PRESS_STREAK=0; CRIT_STREAK=0; SWAPACT_STREAK=0; CPU_TOTAL_STREAK=0
  CPU_STREAKS=""; SUSTAINED_CPU=""
  SWAP_HIST=""; SWAP_TREND="unknown"; SWAP_DELTA_MB=0; SWAP_SPAN_MIN=0
  VERDICT="UNKNOWN"; VERDICT_REASON=""; PREV_VERDICT=""; MEM_ELEVATED=0; MEM_CRITICAL=0; MEM_SWAPPING=0
  PREV_DISK_STATE=""; LAST_HISTORY_TS=0; HISTORY_APPENDS=0; DISK_TS=0; BATT_TS=0
  DISK_INTERVAL=60; TICKS=0; EVENT_LINES=""; RECENT_EVENTS=""
}

# =============================================================================
# Small utilities
# =============================================================================
have() { command -v "$1" >/dev/null 2>&1; }
now_epoch() { date +%s; }
is_uint() { case ${1:-} in ''|*[!0-9]*) return 1 ;; esac; return 0; }
is_int() { case ${1:-} in -*) is_uint "${1#-}" ;; *) is_uint "${1:-}" ;; esac; }
is_tty() { [ -t 0 ] && [ -t 1 ]; }

tilde_path() { case $1 in "$HOME") printf '~' ;; "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# MB -> "850 MB" / "1.2 GB" (handles negatives for deltas)
fmt_mb() {
  local v=${1:-0} sign="" t
  is_int "$v" || { printf 'n/a'; return; }
  if [ "$v" -lt 0 ]; then sign="-"; v=$((-v)); fi
  if [ "$v" -ge 1024 ]; then
    t=$(( (v * 10 + 512) / 1024 ))
    printf '%s%d.%d GB' "$sign" $((t / 10)) $((t % 10))
  else
    printf '%s%d MB' "$sign" "$v"
  fi
}
fmt_mb_signed() { if is_int "${1:-}" && [ "$1" -ge 0 ]; then printf '+%s' "$(fmt_mb "$1")"; else fmt_mb "${1:-}"; fi; }

# Single-quote a string for a command the user may paste into bash/zsh: a'b -> 'a'\''b'
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

fmt_duration() {
  local s=${1:-0} d h m
  is_uint "$s" || { printf 'n/a'; return; }
  d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
  if [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

bar() {
  local pct=${1:-0} w=${2:-20} f i=0 s=""
  is_uint "$pct" || pct=0
  [ "$pct" -gt 100 ] && pct=100
  f=$((pct * w / 100))
  while [ "$i" -lt "$w" ]; do
    if [ "$i" -lt "$f" ]; then s="$s#"; else s="$s."; fi
    i=$((i + 1))
  done
  printf '[%s]' "$s"
}

# Run a command with a time limit (macOS has no `timeout`). The watcher is
# always reaped before returning, so no background job outlives the call.
run_with_timeout() {
  local secs=$1 cmd_pid w_pid rc
  shift
  "$@" &
  cmd_pid=$!
  (
    sp=""
    trap 'if [ -n "$sp" ]; then kill "$sp" 2>/dev/null; fi; exit 0' TERM
    sleep "$secs" & sp=$!
    wait "$sp"
    kill -TERM "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  w_pid=$!
  wait "$cmd_pid"; rc=$?
  kill -TERM "$w_pid" 2>/dev/null
  wait "$w_pid" 2>/dev/null
  return "$rc"
}

# Redact things that look like secrets in a command line (display only).
redact_args() {
  awk '{
    out = ""; redact_next = 0
    for (i = 1; i <= NF; i++) {
      t = $i; low = tolower(t)
      if (redact_next) { t = "[REDACTED]"; redact_next = 0 }
      else if (low ~ /(token|secret|passw|passwd|pwd|api[_-]?key|apikey|auth|bearer|cookie|session|credential|private[_-]?key)/) {
        if (index(t, "=") > 0) t = substr(t, 1, index(t, "=")) "[REDACTED]"
        else if (t ~ /^-/) redact_next = 1
        else t = "[REDACTED]"
      }
      else if (t ~ /:\/\/[^\/@]+@/) { sub(/:\/\/[^\/@]+@/, "://[REDACTED]@", t) }
      else if (length(t) >= 32 && t !~ /^-/ && t ~ /[0-9]/ && t ~ /^[A-Za-z0-9_+\/=.-]+$/ && t !~ /\//) t = "[REDACTED]"
      out = out (i > 1 ? " " : "") t
    }
    print out
  }'
}

# --- UI helpers ---------------------------------------------------------------
setup_colors() {
  C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_YEL=""; C_GRN=""; C_CYN=""
  local mode=$COLOR
  [ -n "${NO_COLOR:-}" ] && mode=never
  [ "$FORCE_NO_COLOR" = 1 ] && mode=never
  if [ "$mode" = always ] || { [ "$mode" = auto ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; }; then
    C_RST=$(printf '\033[0m'); C_B=$(printf '\033[1m'); C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[31m'); C_YEL=$(printf '\033[33m'); C_GRN=$(printf '\033[32m'); C_CYN=$(printf '\033[36m')
  fi
}
section() { printf '\n%s%s%s\n' "$C_B$C_CYN" "$1" "$C_RST"; }
note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST"; }
info() { printf '%s\n' "$*"; }
warn() { printf '%sWarning:%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
badge() {
  case $1 in
    OK) printf '%s[ OK ]%s' "$C_GRN" "$C_RST" ;;
    WATCH) printf '%s[WATCH]%s' "$C_YEL" "$C_RST" ;;
    HIGH) printf '%s[HIGH]%s' "$C_RED" "$C_RST" ;;
    CRITICAL) printf '%s%s[CRITICAL]%s' "$C_B" "$C_RED" "$C_RST" ;;
    LOW) printf '%s[LOW]%s' "$C_YEL" "$C_RST" ;;
    *) printf '[ ?? ]' ;;
  esac
}
ask() {   # ask "prompt" -> REPLY_VAL; returns 1 on EOF
  printf '%s' "$1"
  REPLY_VAL=""
  IFS= read -r REPLY_VAL || { printf '\n'; return 1; }
  return 0
}
pause() { is_tty || return 0; printf '\n%sPress Enter to continue...%s' "$C_DIM" "$C_RST"; IFS= read -r _ || true; }

# =============================================================================
# Configuration (parsed, never sourced: config.env cannot execute code)
# =============================================================================
set_defaults() {
  LIVE_INTERVAL_SEC=4
  WORK_INTERVAL_SEC=30
  WORK_RELAXED_INTERVAL_SEC=60
  WORK_RELAX_AFTER_SAMPLES=10
  DEV_CANDIDATE_MIN_MB=100
  SESSION_REPORT_ENABLED=true
  AUTO_STOP_IDLE_TSSERVER=false
  AUTO_TSSERVER_IDLE_MIN=30
  AUTO_STOP_IDLE_DEVSERVER=false
  AUTO_DEVSERVER_IDLE_MIN=30
  AUTO_CLEAN_MANAGER_TEMP=false
  AUTO_ACTION_GRACE_SEC=60
  AUTO_COOLDOWN_MIN=10
  AUTO_MAX_ACTIONS=4
  AUTO_MAX_INEFFECTIVE=2
  DISK_CHECK_INTERVAL_SEC=600
  SUSTAINED_SAMPLES=3
  PRESSURE_WARN_FREE_PCT=20
  PRESSURE_CRIT_FREE_PCT=10
  SWAP_GROWTH_WARN_MB=1024
  SWAP_TREND_WINDOW_MIN=30
  SWAPOUT_RATE_WARN_PAGES=50
  CPU_PROC_WARN_PCT=80
  CPU_TOTAL_WARN_PCT=85
  DISK_FREE_WARN_GB=20
  DISK_FREE_CRIT_GB=10
  APP_HEAVY_PCT=10
  APP_HEAVY_CAP_MB=1024   # not configurable: upper bound for the APP_HEAVY_PCT cutoff on large-RAM Macs
  APP_CANDIDATE_MIN_MB=300
  TOP_N=15
  LOGGING_ENABLED=true
  LOG_MAX_KB=512
  HISTORY_ENABLED=true
  HISTORY_INTERVAL_SEC=60
  HISTORY_MAX_LINES=5000
  REPORT_KEEP=20
  NOTIFICATIONS_ENABLED=true
  NOTIFY_COOLDOWN_MIN=30
  KILL_GRACE_SEC=10
  SCAN_MAX_DEPTH=6
  COLOR=auto
  DATA_DIR=""
}

config_warn() { CONFIG_WARNINGS="${CONFIG_WARNINGS}${CONFIG_WARNINGS:+$NL}$*"; }

cfg_int() {   # key value min max line
  local key=$1 val=$2 min=$3 max=$4 ln=$5
  if is_uint "$val" && [ ${#val} -le 9 ] && [ $((10#$val)) -ge "$min" ] && [ $((10#$val)) -le "$max" ]; then
    printf -v "$key" '%s' "$((10#$val))"
  else
    config_warn "line $ln: $key='$val' is invalid (expected a whole number $min-$max); keeping ${!key}"
  fi
}
cfg_bool() {
  local key=$1 val ln=$3
  val=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
  case $val in
    true|yes|on|1) printf -v "$key" '%s' true ;;
    false|no|off|0) printf -v "$key" '%s' false ;;
    *) config_warn "line $ln: $key='$2' is invalid (expected true/false); keeping ${!key}" ;;
  esac
}
cfg_path() {
  local key=$1 val=$2 ln=$3
  case $val in "~") val=$HOME ;; "~/"*) val="$HOME/${val#\~/}" ;; esac
  case $val in
    "") printf -v "$key" '%s' "" ;;
    /*) printf -v "$key" '%s' "$val" ;;
    *) config_warn "line $ln: $key must be an absolute path (got '$2'); ignored" ;;
  esac
}

apply_config_value() {
  local key=$1 val=$2 ln=$3
  case $key in
    LIVE_INTERVAL_SEC) cfg_int "$key" "$val" 2 60 "$ln" ;;
    WORK_INTERVAL_SEC|WORK_RELAXED_INTERVAL_SEC) cfg_int "$key" "$val" 5 3600 "$ln" ;;
    WORK_RELAX_AFTER_SAMPLES) cfg_int "$key" "$val" 0 1000 "$ln" ;;
    DEV_CANDIDATE_MIN_MB) cfg_int "$key" "$val" 1 1048576 "$ln" ;;
    AUTO_TSSERVER_IDLE_MIN|AUTO_DEVSERVER_IDLE_MIN) cfg_int "$key" "$val" 1 10080 "$ln" ;;
    AUTO_COOLDOWN_MIN) cfg_int "$key" "$val" 1 1440 "$ln" ;;
    AUTO_MAX_ACTIONS) cfg_int "$key" "$val" 0 100 "$ln" ;;
    AUTO_MAX_INEFFECTIVE) cfg_int "$key" "$val" 1 10 "$ln" ;;
    AUTO_ACTION_GRACE_SEC) cfg_int "$key" "$val" 10 600 "$ln" ;;
    DISK_CHECK_INTERVAL_SEC) cfg_int "$key" "$val" 60 86400 "$ln" ;;
    SUSTAINED_SAMPLES) cfg_int "$key" "$val" 1 60 "$ln" ;;
    PRESSURE_WARN_FREE_PCT|PRESSURE_CRIT_FREE_PCT) cfg_int "$key" "$val" 1 99 "$ln" ;;
    SWAP_GROWTH_WARN_MB) cfg_int "$key" "$val" 1 1048576 "$ln" ;;
    SWAP_TREND_WINDOW_MIN) cfg_int "$key" "$val" 5 1440 "$ln" ;;
    SWAPOUT_RATE_WARN_PAGES) cfg_int "$key" "$val" 1 1000000 "$ln" ;;
    CPU_PROC_WARN_PCT) cfg_int "$key" "$val" 1 3200 "$ln" ;;
    CPU_TOTAL_WARN_PCT) cfg_int "$key" "$val" 1 100 "$ln" ;;
    DISK_FREE_WARN_GB|DISK_FREE_CRIT_GB) cfg_int "$key" "$val" 1 100000 "$ln" ;;
    APP_HEAVY_PCT) cfg_int "$key" "$val" 1 100 "$ln" ;;
    APP_CANDIDATE_MIN_MB) cfg_int "$key" "$val" 1 1048576 "$ln" ;;
    TOP_N) cfg_int "$key" "$val" 5 50 "$ln" ;;
    LOG_MAX_KB) cfg_int "$key" "$val" 16 102400 "$ln" ;;
    HISTORY_INTERVAL_SEC) cfg_int "$key" "$val" 10 3600 "$ln" ;;
    HISTORY_MAX_LINES) cfg_int "$key" "$val" 100 100000 "$ln" ;;
    REPORT_KEEP) cfg_int "$key" "$val" 1 1000 "$ln" ;;
    NOTIFY_COOLDOWN_MIN) cfg_int "$key" "$val" 1 1440 "$ln" ;;
    KILL_GRACE_SEC) cfg_int "$key" "$val" 1 120 "$ln" ;;
    SCAN_MAX_DEPTH) cfg_int "$key" "$val" 1 20 "$ln" ;;
    LOGGING_ENABLED|HISTORY_ENABLED|NOTIFICATIONS_ENABLED|SESSION_REPORT_ENABLED|AUTO_STOP_IDLE_TSSERVER|AUTO_STOP_IDLE_DEVSERVER|AUTO_CLEAN_MANAGER_TEMP) cfg_bool "$key" "$val" "$ln" ;;
    COLOR)
      case $val in auto|always|never) COLOR=$val ;;
        *) config_warn "line $ln: COLOR='$val' is invalid (auto/always/never); keeping $COLOR" ;; esac ;;
    DATA_DIR) cfg_path "$key" "$val" "$ln" ;;
    *) config_warn "line $ln: unknown setting '$key' ignored" ;;
  esac
}

load_config() {   # [explicit file]
  local explicit=${1:-} file line key val ln=0
  if [ -n "$explicit" ]; then file=$explicit
  elif [ -n "${MPM_CONFIG:-}" ]; then file=$MPM_CONFIG; explicit=$file
  else file="$SCRIPT_DIR/config.env"; fi
  CONFIG_FILE=$file
  if [ ! -e "$file" ]; then
    if [ -n "$explicit" ]; then
      config_warn "config file not found: $file (using built-in defaults)"
      CONFIG_STATUS="not found, using defaults"
    else
      CONFIG_STATUS="no config.env, using defaults"
    fi
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    config_warn "config file is not a readable file: $file (using defaults)"
    CONFIG_STATUS="unreadable, using defaults"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    line=${line%"$(printf '\r')"}
    line=$(trim "$line")
    case $line in ''|'#'*) continue ;; esac
    case $line in export\ *) line=$(trim "${line#export }") ;; esac
    case $line in *=*) ;; *) config_warn "line $ln: expected KEY=VALUE, ignored"; continue ;; esac
    key=$(trim "${line%%=*}")
    val=${line#*=}
    case $val in *" #"*) val=${val%% #*} ;; esac
    val=$(trim "$val")
    case $val in \"*\") val=${val#\"}; val=${val%\"} ;; \'*\') val=${val#\'}; val=${val%\'} ;; esac
    case $key in ''|[0-9]*|*[!A-Z0-9_]*) config_warn "line $ln: invalid key '$key', ignored"; continue ;; esac
    apply_config_value "$key" "$val" "$ln"
  done < "$file"
  if [ "$PRESSURE_CRIT_FREE_PCT" -ge "$PRESSURE_WARN_FREE_PCT" ]; then
    config_warn "PRESSURE_CRIT_FREE_PCT must be lower than PRESSURE_WARN_FREE_PCT; using 20/10"
    PRESSURE_WARN_FREE_PCT=20; PRESSURE_CRIT_FREE_PCT=10
  fi
  if [ "$WORK_RELAXED_INTERVAL_SEC" -lt "$WORK_INTERVAL_SEC" ]; then
    config_warn "WORK_RELAXED_INTERVAL_SEC must not be lower than WORK_INTERVAL_SEC; using $WORK_INTERVAL_SEC"
    WORK_RELAXED_INTERVAL_SEC=$WORK_INTERVAL_SEC
  fi
  if [ "$DISK_FREE_CRIT_GB" -ge "$DISK_FREE_WARN_GB" ]; then
    config_warn "DISK_FREE_CRIT_GB must be lower than DISK_FREE_WARN_GB; using 20/10"
    DISK_FREE_WARN_GB=20; DISK_FREE_CRIT_GB=10
  fi
  CONFIG_STATUS="loaded"
}

print_config() {
  info "Config file: ${CONFIG_FILE:-none} ($CONFIG_STATUS)"
  local k
  for k in LIVE_INTERVAL_SEC WORK_INTERVAL_SEC WORK_RELAXED_INTERVAL_SEC WORK_RELAX_AFTER_SAMPLES \
    DEV_CANDIDATE_MIN_MB SESSION_REPORT_ENABLED AUTO_STOP_IDLE_TSSERVER AUTO_TSSERVER_IDLE_MIN \
    AUTO_STOP_IDLE_DEVSERVER AUTO_DEVSERVER_IDLE_MIN AUTO_CLEAN_MANAGER_TEMP AUTO_ACTION_GRACE_SEC \
    AUTO_COOLDOWN_MIN AUTO_MAX_ACTIONS AUTO_MAX_INEFFECTIVE \
    DISK_CHECK_INTERVAL_SEC SUSTAINED_SAMPLES \
    PRESSURE_WARN_FREE_PCT PRESSURE_CRIT_FREE_PCT SWAP_GROWTH_WARN_MB SWAP_TREND_WINDOW_MIN \
    SWAPOUT_RATE_WARN_PAGES CPU_PROC_WARN_PCT CPU_TOTAL_WARN_PCT DISK_FREE_WARN_GB DISK_FREE_CRIT_GB \
    APP_HEAVY_PCT APP_CANDIDATE_MIN_MB TOP_N LOGGING_ENABLED LOG_MAX_KB HISTORY_ENABLED \
    HISTORY_INTERVAL_SEC HISTORY_MAX_LINES REPORT_KEEP NOTIFICATIONS_ENABLED NOTIFY_COOLDOWN_MIN \
    KILL_GRACE_SEC SCAN_MAX_DEPTH COLOR DATA_DIR; do
    printf '  %-26s %s\n' "$k" "${!k}"
  done
  if [ -n "$CONFIG_WARNINGS" ]; then
    info "Warnings:"
    printf '%s\n' "$CONFIG_WARNINGS" | sed 's/^/  - /'
  fi
}

# =============================================================================
# Platform detection
# =============================================================================
check_utilities() {
  local missing="" u
  for u in sysctl vm_stat ps df awk sort head tail; do have "$u" || missing="$missing $u"; done
  [ -z "$missing" ] || die "required system utilities not found:$missing. This tool needs macOS's built-in tools."
  HAVE_TOP=0; HAVE_PMSET=0; HAVE_LSOF=0; HAVE_OSASCRIPT=0; HAVE_MP=0; HAVE_SP=0; HAVE_DOCKER=0; HAVE_GIT=0; HAVE_DU=0; HAVE_FIND=0
  have top && HAVE_TOP=1
  have pmset && HAVE_PMSET=1
  have lsof && HAVE_LSOF=1
  have osascript && HAVE_OSASCRIPT=1
  have memory_pressure && HAVE_MP=1
  have system_profiler && HAVE_SP=1
  have docker && HAVE_DOCKER=1
  have du && HAVE_DU=1
  have find && HAVE_FIND=1
  if have git; then
    # /usr/bin/git is a stub that pops up an installer if Command Line Tools are missing.
    if [ "$OS_NAME" = Darwin ] && [ "$(command -v git)" = /usr/bin/git ]; then
      xcode-select -p >/dev/null 2>&1 && HAVE_GIT=1
    else
      HAVE_GIT=1
    fi
  fi
}

detect_platform() {
  OS_NAME=$(uname -s 2>/dev/null || echo unknown)
  if [ "$OS_NAME" != Darwin ] && [ "${MPM_ALLOW_NON_DARWIN:-0}" != 1 ]; then
    die "this tool supports macOS only (detected: $OS_NAME)."
  fi
  ARCH=$(uname -m 2>/dev/null || echo unknown)
  check_utilities
  MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null) || MACOS_VERSION="unknown"
  MACOS_BUILD=$(sw_vers -buildVersion 2>/dev/null) || MACOS_BUILD=""
  HW_MODEL=$(sysctl -n hw.model 2>/dev/null) || HW_MODEL=""
  CPU_BRAND=$(sysctl -n machdep.cpu.brand_string 2>/dev/null) || CPU_BRAND=""
  NCPU=$(sysctl -n hw.ncpu 2>/dev/null); is_uint "$NCPU" && [ "$NCPU" -gt 0 ] || NCPU=1
  PCORES=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null); is_uint "$PCORES" || PCORES=""
  ECORES=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null); is_uint "$ECORES" || ECORES=""
  TRANSLATED=$(sysctl -n sysctl.proc_translated 2>/dev/null); is_uint "$TRANSLATED" || TRANSLATED=0
  local mb; mb=$(sysctl -n hw.memsize 2>/dev/null)
  is_uint "$mb" || die "could not read physical memory size (sysctl hw.memsize)."
  MEM_TOTAL_MB=$((mb / 1048576))
  PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null)
  if ! is_uint "$PAGE_SIZE"; then
    if [ "$ARCH" = arm64 ]; then PAGE_SIZE=16384; else PAGE_SIZE=4096; fi
  fi
  CURRENT_UID=$(id -u)
}

use_data_dir() {   # dir -> 0 if logs/, reports/ and state/ exist (or were created) and are writable
  DATA_DIR=$1
  LOG_DIR="$DATA_DIR/logs"; REPORT_DIR="$DATA_DIR/reports"; STATE_DIR="$DATA_DIR/state"
  EVENT_LOG="$LOG_DIR/events.log"; HISTORY_FILE="$STATE_DIR/history.tsv"; PIDFILE="$STATE_DIR/work.pid"
  mkdir -p "$LOG_DIR" "$REPORT_DIR" "$STATE_DIR" 2>/dev/null && [ -w "$STATE_DIR" ] && [ -w "$LOG_DIR" ] && [ -w "$REPORT_DIR" ]
}

init_dirs() {
  DIRS_OK=0
  if [ -n "$DATA_DIR" ]; then
    use_data_dir "$DATA_DIR" && DIRS_OK=1   # set in config: used as is, never replaced
  elif use_data_dir "$SCRIPT_DIR"; then
    DIRS_OK=1
  else
    # Script folder not writable (e.g. installed system-wide): keep the data in a per-user folder.
    use_data_dir "$HOME/Library/Application Support/mac-performance-manager" && DIRS_OK=1
  fi
  if [ "$DIRS_OK" != 1 ]; then
    LOGGING_ENABLED=false; HISTORY_ENABLED=false
    warn "cannot write to $DATA_DIR; logging, history and reports are disabled."
  fi
}

load_model_name() {
  [ -n "$MODEL_NAME" ] && return 0
  local cache="$STATE_DIR/static.cache" line cached_model="" cached_name=""
  if [ "$DIRS_OK" = 1 ] && [ -f "$cache" ]; then
    while IFS= read -r line; do
      case $line in HW_MODEL=*) cached_model=${line#HW_MODEL=} ;; MODEL_NAME=*) cached_name=${line#MODEL_NAME=} ;; esac
    done < "$cache"
    if [ "$cached_model" = "$HW_MODEL" ] && [ -n "$cached_name" ]; then MODEL_NAME=$cached_name; return 0; fi
  fi
  # system_profiler is slow (~1 s); run once and cache. Only the model name is kept.
  if [ "$HAVE_SP" = 1 ]; then
    MODEL_NAME=$(run_with_timeout 20 system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name:/ { print $2; exit }')
  fi
  [ -n "$MODEL_NAME" ] || MODEL_NAME="Mac"
  if [ "$DIRS_OK" = 1 ]; then
    printf 'HW_MODEL=%s\nMODEL_NAME=%s\n' "$HW_MODEL" "$MODEL_NAME" > "$cache" 2>/dev/null
  fi
}

# =============================================================================
# Logging & history (small, local, rotated; no command lines are ever logged)
# =============================================================================
rotate_if_needed() {
  local f=$1 max_kb=$2 sz
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  is_uint "$sz" || return 0
  if [ "$sz" -gt $((max_kb * 1024)) ]; then mv -f -- "$f" "$f.1" 2>/dev/null; fi
}

log_event() {   # level message
  [ "$LOGGING_ENABLED" = true ] && [ "$DIRS_OK" = 1 ] || return 0
  local msg; msg=$(printf '%s' "$2" | tr '\t\r\n' '   ')
  rotate_if_needed "$EVENT_LOG" "$LOG_MAX_KB"
  printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$msg" >> "$EVENT_LOG" 2>/dev/null
}

record_history() {   # now
  [ "$HISTORY_ENABLED" = true ] && [ "$DIRS_OK" = 1 ] && [ "$SWAP_OK" = 1 ] || return 0
  [ $(($1 - LAST_HISTORY_TS)) -ge "$HISTORY_INTERVAL_SEC" ] || return 0
  LAST_HISTORY_TS=$1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$SWAP_USED_MB" "${PRESS_LEVEL:-}" "${FREE_PCT:-}" "$MEM_COMP_MB" "$DISK_AVAIL_MB" >> "$HISTORY_FILE" 2>/dev/null
  HISTORY_APPENDS=$((HISTORY_APPENDS + 1))
  [ $((HISTORY_APPENDS % 100)) -eq 1 ] && trim_history
}

trim_history() {
  [ -f "$HISTORY_FILE" ] || return 0
  local n; n=$(wc -l < "$HISTORY_FILE" | tr -d ' ')
  if is_uint "$n" && [ "$n" -gt "$HISTORY_MAX_LINES" ]; then
    tail -n "$HISTORY_MAX_LINES" "$HISTORY_FILE" > "$HISTORY_FILE.tmp.$$" 2>/dev/null &&
      mv -f -- "$HISTORY_FILE.tmp.$$" "$HISTORY_FILE"
    rm -f -- "$HISTORY_FILE.tmp.$$" 2>/dev/null
  fi
}

seed_swap_history() {   # now
  SWAP_HIST=""
  [ "$DIRS_OK" = 1 ] && [ -f "$HISTORY_FILE" ] || return 0
  SWAP_HIST=$(tail -n 2000 "$HISTORY_FILE" 2>/dev/null | awk -F'\t' -v c=$(($1 - SWAP_TREND_WINDOW_MIN * 60)) \
    '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $1 >= c { print $1 "\t" $2 }')
}

# =============================================================================
# Parsers (pure: stdin -> stdout, unit-tested with fixtures)
# =============================================================================
# vm_stat -> "pagesize free active inactive speculative throttled wired purgeable
#             filebacked anonymous stored occupied pageins pageouts swapins swapouts"
parse_vm_stat() {
  awk '
    /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1) + 0 }
    index($0, ":") > 0 {
      k = substr($0, 1, index($0, ":") - 1); gsub(/"/, "", k)
      v = substr($0, index($0, ":") + 1); gsub(/[^0-9]/, "", v)
      if (v != "") val[k] = v + 0
    }
    END {
      split("Pages free|Pages active|Pages inactive|Pages speculative|Pages throttled|Pages wired down|Pages purgeable|File-backed pages|Anonymous pages|Pages stored in compressor|Pages occupied by compressor|Pageins|Pageouts|Swapins|Swapouts", keys, "|")
      line = sprintf("%.0f", ps + 0)
      for (i = 1; i <= 15; i++) line = line " " sprintf("%.0f", val[keys[i]] + 0)
      print line
    }'
}

# sysctl vm.swapusage -> "total_mb used_mb free_mb"
parse_swapusage() {
  awk '
    function mb(x,   n, u) { n = x + 0; u = substr(x, length(x), 1)
      if (u == "G") n *= 1024; else if (u == "K") n /= 1024; else if (u == "T") n *= 1048576; return n }
    { for (i = 1; i + 2 <= NF; i++) if ($(i + 1) == "=") {
        if ($i == "total") t = mb($(i + 2)); else if ($i == "used") u = mb($(i + 2)); else if ($i == "free") f = mb($(i + 2)) } }
    END { if (t == "" && u == "") exit 1; printf "%d %d %d\n", t + 0.5, u + 0.5, f + 0.5 }'
}

# df -Pk -> "total_kb used_kb avail_kb"
parse_df() { awk 'NR > 1 && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print $2, $3, $4; exit }'; }

# pmset -g batt -> "source|percent|state"
parse_pmset_batt() {
  awk '
    /drawing from/ { if ($0 ~ /AC Power/) src = "AC power"; else if ($0 ~ /Battery Power/) src = "battery"; else src = "other" }
    /InternalBattery/ {
      if (match($0, /[0-9]+%/)) pct = substr($0, RSTART, RLENGTH - 1)
      n = split($0, a, ";"); st = (n >= 2) ? a[2] : ""; gsub(/^[ \t]+|[ \t]+$/, "", st)
    }
    END { if (src == "") src = "unknown"; if (pct == "") pct = "-"; if (st == "") st = "-"; print src "|" pct "|" st }'
}

# memory_pressure (no arguments = read-only stats) -> free percentage
parse_memory_pressure_free() { awk -F: '/memory free percentage/ { v = $2; gsub(/[^0-9]/, "", v); print v; exit }'; }

# top -l 2 -s 1 -stats pid,cpu,mem -> "C user sys idle" + "T pid cpu mem_kb" (2nd sample only:
# the 1st sample's CPU numbers are not meaningful)
parse_top() {
  awk '
    function tokb(x,   n, u) { u = x; gsub(/[0-9.+-]/, "", u); n = x; gsub(/[^0-9.]/, "", n)
      if (n == "") return -1; n += 0
      if (u == "B") return int(n / 1024); if (u == "K") return int(n); if (u == "M") return int(n * 1024)
      if (u == "G") return int(n * 1048576); if (u == "T") return int(n * 1073741824); return -1 }
    /^Processes:/ { sample++; hdr = 0; next }
    sample == 2 && /^CPU usage:/ { line = $0; gsub(/%/, "", line); n = split(line, a, /[ ,]+/)
      for (i = 2; i <= n; i++) { if (a[i] == "user") u = a[i-1]; if (a[i] == "sys") s = a[i-1]; if (a[i] == "idle") d = a[i-1] }
      if (u != "") print "C", u, s, d; next }
    sample == 2 && $1 == "PID" { for (i = 1; i <= NF; i++) { if ($i == "PID") cp = i; if ($i == "%CPU") cc = i; if ($i == "MEM") cm = i }
      hdr = (cp && cc && cm); next }
    sample == 2 && hdr && $1 ~ /^[0-9]+$/ { c = $cc; gsub(/[^0-9.]/, "", c); print "T", $cp, (c == "" ? 0 : c), tokb($cm) }'
}

# Enrich `ps -Axo pid=,ppid=,uid=,rss=,%cpu=,comm=` (after a "#PS" marker, optionally
# preceded by parse_top output) into TSV:
#  1 pid 2 ppid 3 uid 4 rss_kb 5 cpu 6 mem_kb 7 src(F=footprint,R=rss) 8 app 9 category
#  10 name 11 started_by 12 role 13 executable path
enrich_procs() {
  awk '
    function helper_role(b, a) {
      if (b ~ /\(Renderer\)/) return "renderer"
      if (b ~ /\(GPU\)/) return "gpu"
      if (b ~ /\(Plugin\)/) return "plugin"
      if (b ~ / Helper$/ || b ~ / Helper \(/) return "utility"
      if (b == a || index(a, b) == 1 || index(b, a) == 1) return "main"
      return "tool"
    }
    function classify(path,   i, a, low, sysp) {
      BASE = path; sub(/.*\//, "", BASE); if (BASE == "") BASE = path
      APP = ""; CAT = ""; ROLE = "-"; ISAPP = 0
      sysp = (path ~ /^\/(System|usr\/libexec|usr\/sbin|sbin|usr\/bin|bin|Library\/Apple)\//)
      i = index(path, ".app/"); if (i == 0 && path ~ /\.app$/) i = length(path) - 3
      if (i > 0) {
        a = substr(path, 1, i - 1); sub(/.*\//, "", a); ISAPP = 1
        if (a ~ /^Brave Browser/) a = "Brave"; else if (a ~ /^Google Chrome/) a = "Chrome"
        APP = a
        if (a == "Cursor") CAT = "Cursor"; else if (a == "Brave") CAT = "Brave"
        else if (a ~ /^ChatGPT/) CAT = "ChatGPT"
        else if (a ~ /^(Docker|OrbStack|Rancher Desktop)$/) CAT = "Docker"
        else if (a == "Python") CAT = "Python"
        else if (sysp) CAT = "System"
        else CAT = "App"
        ROLE = helper_role(BASE, a); return
      }
      low = tolower(BASE)
      if (low ~ /^node(js)?[0-9.]*$/) { APP = "Node.js"; CAT = "Node.js" }
      else if (low ~ /^python[0-9.]*$/) { APP = "Python"; CAT = "Python" }
      else if (low ~ /^(bun|deno)$/) { APP = BASE; CAT = "JS runtime" }
      else if (low ~ /^com\.docker\./ || low ~ /^(dockerd|containerd|vpnkit.*|docker|docker-proxy|qemu-system.*|limactl)$/) { APP = "Docker"; CAT = "Docker" }
      else if (low ~ /virtualization\.virtualmachine/) { APP = "Virtual machine"; CAT = "VM" }
      else if (low ~ /^(postgres|postmaster|mysqld|mariadbd|mongod|mongos|redis-server|valkey-server|clickhouse.*|meilisearch|elasticsearch)$/) { APP = BASE; CAT = "Database" }
      else if (low ~ /^(ollama|llama-server|llama-cli|llamafile|lms)$/) { APP = BASE; CAT = "Local AI" }
      else if (sysp || low ~ /^(kernel_task|launchd)$/) { APP = BASE; CAT = "System" }
      else { APP = BASE; CAT = "Other" }
    }
    $0 == "#PS" { inps = 1; next }
    !inps && $1 == "T" { tcpu[$2] = $3; tmem[$2] = $4; next }
    !inps { next }
    {
      line = $0
      if (!match(line, /^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[0-9.]+[ \t]+/)) next
      path = substr(line, RLENGTH + 1); gsub(/\t/, " ", path)
      pid = $1; n++; P[n] = pid; ppid[pid] = $2; uid[pid] = $3; rss[pid] = $4; cpu[pid] = $5; cpath[pid] = path
      classify(path); app[pid] = APP; cat[pid] = CAT; base[pid] = BASE; role[pid] = ROLE; isapp[pid] = ISAPP
    }
    END {
      for (i = 1; i <= n; i++) {
        p = P[i]; mem = rss[p]; src = "R"
        if ((p in tmem) && tmem[p] >= 0) { mem = tmem[p]; src = "F" }
        c = cpu[p]; if (p in tcpu) c = tcpu[p]
        own = "-"; owncat = ""; q = ppid[p]; d = 0
        while (q != "" && q + 0 > 1 && d < 64) {
          if ((q in isapp) && isapp[q] && app[q] != app[p]) { own = app[q]; owncat = cat[q]; break }
          q = ppid[q]; d++
        }
        a = app[p]; k = cat[p]; r = role[p]
        # Cursor helpers that rename themselves ("Cursor Helper (Plugin): extension-host ...") and the
        # unclassified tools Cursor starts (tsserver, extension binaries) belong to Cursor: they go
        # away when its windows close. Known runtimes (Node.js, Python, ...) keep their own group.
        if (k == "Other" && owncat == "Cursor") { a = own; k = "Cursor"; r = (base[p] ~ /\(Plugin\)/ ? "plugin" : "tool") }
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", p, ppid[p], uid[p], rss[p], c, mem, src, a, k, base[p], own, r, cpath[p]
      }
    }'
}

# =============================================================================
# Collectors
# =============================================================================
collect_memory() {
  local out
  out=$(vm_stat 2>/dev/null | parse_vm_stat)
  # shellcheck disable=SC2086
  set -- $out
  if [ $# -ne 16 ]; then MEM_OK=0; return 1; fi
  VM_PS=$1; VM_FREE=$2; VM_ACTIVE=$3; VM_INACTIVE=$4; VM_SPEC=$5; VM_THROTTLED=$6; VM_WIRED=$7
  VM_PURGEABLE=$8; VM_FILEBACKED=$9; VM_ANON=${10}; VM_STORED=${11}; VM_OCCUPIED=${12}
  VM_PAGEINS=${13}; VM_PAGEOUTS=${14}; VM_SWAPINS=${15}; VM_SWAPOUTS=${16}
  [ "$VM_PS" -gt 0 ] || VM_PS=$PAGE_SIZE
  local app_pages=$((VM_ANON - VM_PURGEABLE))
  if [ "$VM_ANON" -eq 0 ]; then app_pages=$((VM_ACTIVE + VM_INACTIVE + VM_SPEC - VM_FILEBACKED - VM_PURGEABLE)); fi
  [ "$app_pages" -lt 0 ] && app_pages=0
  MEM_APP_MB=$((app_pages * VM_PS / 1048576))
  MEM_WIRED_MB=$((VM_WIRED * VM_PS / 1048576))
  MEM_COMP_MB=$((VM_OCCUPIED * VM_PS / 1048576))
  MEM_STORED_MB=$((VM_STORED * VM_PS / 1048576))
  MEM_CACHED_MB=$(((VM_FILEBACKED + VM_PURGEABLE) * VM_PS / 1048576))
  MEM_FREE_MB=$(((VM_FREE + VM_SPEC) * VM_PS / 1048576))
  MEM_USED_MB=$((MEM_APP_MB + MEM_WIRED_MB + MEM_COMP_MB))
  COMP_RATIO_X10=0
  [ "$VM_OCCUPIED" -gt 0 ] && COMP_RATIO_X10=$((VM_STORED * 10 / VM_OCCUPIED))
  MEM_OK=1
}

collect_pressure() {
  PRESS_LEVEL=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
  is_uint "$PRESS_LEVEL" || PRESS_LEVEL=""
  FREE_PCT=$(sysctl -n kern.memorystatus_level 2>/dev/null)
  PRESS_SOURCE="sysctl"
  if ! is_uint "$FREE_PCT"; then
    FREE_PCT=""
    if [ "$HAVE_MP" = 1 ]; then
      # No arguments = read-only report. Never pass -l/-p (those simulate pressure).
      FREE_PCT=$(run_with_timeout 5 memory_pressure 2>/dev/null | parse_memory_pressure_free)
      is_uint "$FREE_PCT" && PRESS_SOURCE="memory_pressure" || FREE_PCT=""
    fi
  fi
  MEM_AVAIL_EST_MB=""
  [ -n "$FREE_PCT" ] && MEM_AVAIL_EST_MB=$((MEM_TOTAL_MB * FREE_PCT / 100))
}

pressure_text() {
  case ${PRESS_LEVEL:-} in 1) echo "normal" ;; 2) echo "WARNING" ;; 4) echo "CRITICAL" ;; *) echo "unknown" ;; esac
}

collect_swap() {
  local out
  out=$(sysctl -n vm.swapusage 2>/dev/null | parse_swapusage)
  # shellcheck disable=SC2086
  set -- $out
  if [ $# -eq 3 ]; then SWAP_TOTAL_MB=$1; SWAP_USED_MB=$2; SWAP_FREE_MB=$3; SWAP_OK=1; else SWAP_OK=0; fi
}

collect_disk() {
  local out
  DISK_TARGET="/"
  [ -d /System/Volumes/Data ] && DISK_TARGET=/System/Volumes/Data
  out=$(df -Pk "$DISK_TARGET" 2>/dev/null | parse_df)
  # shellcheck disable=SC2086
  set -- $out
  if [ $# -eq 3 ] && [ "$1" -gt 0 ]; then
    DISK_TOTAL_MB=$(($1 / 1024)); DISK_AVAIL_MB=$(($3 / 1024))
    DISK_USED_PCT=$(( ($1 - $3) * 100 / $1 )); DISK_OK=1
  else
    DISK_OK=0
  fi
  DISK_TS=$(now_epoch)
  evaluate_disk
}

evaluate_disk() {
  if [ "$DISK_OK" != 1 ]; then DISK_STATE="UNKNOWN"; return; fi
  if [ "$DISK_AVAIL_MB" -lt $((DISK_FREE_CRIT_GB * 1024)) ]; then DISK_STATE="CRITICAL"
  elif [ "$DISK_AVAIL_MB" -lt $((DISK_FREE_WARN_GB * 1024)) ]; then DISK_STATE="LOW"
  else DISK_STATE="OK"; fi
}

collect_battery() {
  BATT_TS=$(now_epoch)
  BATT_SRC=""; BATT_PCT=""; BATT_STATE=""
  [ "$HAVE_PMSET" = 1 ] || return 0
  local out; out=$(pmset -g batt 2>/dev/null | parse_pmset_batt)
  BATT_SRC=${out%%|*}; out=${out#*|}; BATT_PCT=${out%%|*}; BATT_STATE=${out#*|}
}

collect_uptime() {
  local bt now
  bt=$(sysctl -n kern.boottime 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "sec" && $(i+1) == "=") { v = $(i+2); gsub(/[^0-9]/, "", v); print v; exit } }')
  now=$(now_epoch)
  if is_uint "$bt" && [ "$now" -ge "$bt" ]; then UPTIME_SEC=$((now - bt)); else UPTIME_SEC=""; fi
}

collect_load() {
  local out; out=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')
  # shellcheck disable=SC2086
  set -- $out
  LOAD1=${1:-}; LOAD5=${2:-}; LOAD15=${3:-}
}

# collect_procs fast|precise
#   fast:    ps only (RSS + ps's decaying CPU average). Cheap; used by live/work mode.
#   precise: also `top -l 2 -s 1` (~1 s): physical footprint per process (the value
#            Activity Monitor shows) and a true 1-second CPU sample.
collect_procs() {
  local mode=${1:-fast} topdata="" cl
  PROC_MEM_SRC="RSS"; CPU_SRC="ps"; CPU_USER=""; CPU_SYS=""; CPU_IDLE=""
  if [ "$mode" = precise ] && [ "$HAVE_TOP" = 1 ]; then
    topdata=$(top -l 2 -s 1 -stats pid,cpu,mem 2>/dev/null | parse_top)
    if [ -n "$topdata" ]; then
      cl=$(printf '%s\n' "$topdata" | awk '$1 == "C" { print $2, $3, $4; exit }')
      # shellcheck disable=SC2086
      set -- $cl
      if [ $# -eq 3 ]; then CPU_USER=$1; CPU_SYS=$2; CPU_IDLE=$3; CPU_SRC="top"; fi
      PROC_MEM_SRC="FOOTPRINT"
    fi
  fi
  PROCS=$( { [ -n "$topdata" ] && printf '%s\n' "$topdata"; echo '#PS'; ps -Axo pid=,ppid=,uid=,rss=,%cpu=,comm= 2>/dev/null; } | enrich_procs)
  summarize_procs
}

summarize_procs() {
  local s
  s=$(printf '%s\n' "$PROCS" | awk -F'\t' -v self="$$" '
    NF >= 12 {
      if ($1 != self) cpu += $5; n++; m = $6
      if ($9 == "Cursor") { cn++; cm += m; if ($12 == "renderer") cr++; if ($12 == "plugin") cp++; if ($12 == "main") cma++ }
      if ($9 == "Node.js") { nn++; nm += m }
      if ($9 == "Python") { pn++; pm += m }
      if ($9 == "Brave") { bn++; bm += m }
      if ($9 == "Docker" || $9 == "VM") { dn++; dm += m }
      if ($9 == "Local AI") { an++; am += m }
    }
    END { printf "%.0f %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n", cpu, n, cn, cm/1024, cr, cp, cma, nn, nm/1024, pn, pm/1024, bn, bm/1024, dn, dm/1024, an, am/1024 }')
  # shellcheck disable=SC2086
  set -- $s
  [ $# -eq 17 ] || return 0
  SUM_CPU=$1; SUM_NPROCS=$2; SUM_CUR_N=$3; SUM_CUR_MEM=$4; SUM_CUR_REND=$5; SUM_CUR_PLUG=$6; SUM_CUR_MAIN=$7
  SUM_NODE_N=$8; SUM_NODE_MEM=$9; SUM_PY_N=${10}; SUM_PY_MEM=${11}; SUM_BRAVE_N=${12}; SUM_BRAVE_MEM=${13}
  SUM_DOCK_N=${14}; SUM_DOCK_MEM=${15}; SUM_AI_N=${16}; SUM_AI_MEM=${17}
  if [ "$CPU_SRC" = top ] && [ -n "$CPU_IDLE" ]; then
    CPU_TOTAL_PCT=$(awk -v i="$CPU_IDLE" 'BEGIN { v = 100 - i; if (v < 0) v = 0; printf "%.0f", v }')
  else
    CPU_TOTAL_PCT=$((SUM_CPU / NCPU)); [ "$CPU_TOTAL_PCT" -gt 100 ] && CPU_TOTAL_PCT=100
  fi
}

# Per-app totals: app \t category \t count \t mem_kb \t rss_kb \t cpu  (sorted by mem)
group_totals() {
  printf '%s\n' "$PROCS" | awk -F'\t' 'NF >= 12 { k = $8; c[k] = $9; n[k]++; m[k] += $6; r[k] += $4; u[k] += $5 }
    END { for (k in n) printf "%s\t%s\t%d\t%d\t%d\t%.1f\n", k, c[k], n[k], m[k], r[k], u[k] }' | sort -t "$TAB" -k4,4nr
}

# =============================================================================
# Analysis
# =============================================================================
update_rates() {   # now
  local now=$1 dt
  if [ -n "$PREV_TS" ] && [ "$now" -gt "$PREV_TS" ] && [ "$MEM_OK" = 1 ]; then
    dt=$((now - PREV_TS))
    SWAPOUT_RATE=$(( (VM_SWAPOUTS - PREV_SWAPOUTS) / dt ))
    SWAPIN_RATE=$(( (VM_SWAPINS - PREV_SWAPINS) / dt ))
    [ "$SWAPOUT_RATE" -lt 0 ] && SWAPOUT_RATE=0
    [ "$SWAPIN_RATE" -lt 0 ] && SWAPIN_RATE=0
  fi
  if [ "$MEM_OK" = 1 ]; then PREV_TS=$now; PREV_SWAPOUTS=$VM_SWAPOUTS; PREV_SWAPINS=$VM_SWAPINS; fi
}

update_swap_trend() {   # now
  local now=$1 win=$((SWAP_TREND_WINDOW_MIN * 60)) first
  [ "$SWAP_OK" = 1 ] || { SWAP_TREND="unknown"; return; }
  SWAP_HIST=$(printf '%s\n%s\t%s\n' "$SWAP_HIST" "$now" "$SWAP_USED_MB" | awk -F'\t' -v c=$((now - win)) 'NF == 2 && $1 >= c')
  first=$(printf '%s\n' "$SWAP_HIST" | awk 'NR == 1 { print; exit }')
  # shellcheck disable=SC2086
  set -- $first
  if [ $# -ne 2 ]; then SWAP_TREND="unknown"; return; fi
  SWAP_SPAN_MIN=$(( (now - $1) / 60 ))
  SWAP_DELTA_MB=$((SWAP_USED_MB - $2))
  local min_span=$((SWAP_TREND_WINDOW_MIN / 3)); [ "$min_span" -lt 5 ] && min_span=5
  if [ "$SWAP_SPAN_MIN" -lt "$min_span" ]; then SWAP_TREND="collecting"
  elif [ "$SWAP_DELTA_MB" -ge "$SWAP_GROWTH_WARN_MB" ]; then SWAP_TREND="growing"
  elif [ "$SWAP_DELTA_MB" -le $((-SWAP_GROWTH_WARN_MB)) ]; then SWAP_TREND="shrinking"
  else SWAP_TREND="stable"; fi
}

swap_trend_text() {
  case $SWAP_TREND in
    collecting) printf 'collecting history (%sm of data)' "$SWAP_SPAN_MIN" ;;
    unknown) printf 'no history yet' ;;
    *) printf '%s over %sm (%s)' "$(fmt_mb_signed "$SWAP_DELTA_MB")" "$SWAP_SPAN_MIN" "$SWAP_TREND" ;;
  esac
}

update_cpu_streaks() {
  CPU_STREAKS=$( { printf '%s\n' "$CPU_STREAKS"; echo '#NEW'; printf '%s\n' "$PROCS"; } | awk -F'\t' -v t="$CPU_PROC_WARN_PCT" -v self="$$" '
    !n && $0 == "#NEW" { n = 1; next }
    !n && NF >= 3 { prev[$1] = $2; next }
    n && NF >= 12 && $1 != self && $5 + 0 >= t { c = (($1 in prev) ? prev[$1] : 0) + 1; printf "%s\t%d\t%s\t%.1f\n", $1, c, $10, $5 }')
  SUSTAINED_CPU=$(printf '%s\n' "$CPU_STREAKS" | awk -F'\t' -v s="$SUSTAINED_SAMPLES" 'NF >= 4 && $2 >= s')
  if [ "$CPU_TOTAL_PCT" -ge "$CPU_TOTAL_WARN_PCT" ]; then CPU_TOTAL_STREAK=$((CPU_TOTAL_STREAK + 1)); else CPU_TOTAL_STREAK=0; fi
}

# Combine pressure level, macOS free %, and swap-out activity. "RAM nearly full"
# alone is never a problem on macOS; a single sample never raises HIGH/CRITICAL
# unless SUSTAINED_SAMPLES=1.
evaluate_state() {
  local elevated=0 critical=0 swapping=0 S=$SUSTAINED_SAMPLES reasons=""
  case ${PRESS_LEVEL:-} in 2) elevated=1 ;; 4) elevated=1; critical=1 ;; esac
  if [ -n "$FREE_PCT" ]; then
    [ "$FREE_PCT" -lt "$PRESSURE_WARN_FREE_PCT" ] && elevated=1
    [ "$FREE_PCT" -lt "$PRESSURE_CRIT_FREE_PCT" ] && critical=1
  fi
  if is_uint "${SWAPOUT_RATE:-}" && [ "$SWAPOUT_RATE" -ge "$SWAPOUT_RATE_WARN_PAGES" ]; then swapping=1; fi
  if [ "$elevated" = 1 ]; then PRESS_STREAK=$((PRESS_STREAK + 1)); else PRESS_STREAK=0; fi
  if [ "$critical" = 1 ]; then CRIT_STREAK=$((CRIT_STREAK + 1)); else CRIT_STREAK=0; fi
  if [ "$swapping" = 1 ]; then SWAPACT_STREAK=$((SWAPACT_STREAK + 1)); else SWAPACT_STREAK=0; fi
  MEM_ELEVATED=$elevated; MEM_CRITICAL=$critical; MEM_SWAPPING=$swapping

  [ "$elevated" = 1 ] && reasons="memory pressure $(pressure_text)${PRESS_LEVEL:+ (kernel level $PRESS_LEVEL)}${FREE_PCT:+, macOS free estimate $FREE_PCT%}"
  [ "$swapping" = 1 ] && reasons="${reasons:+$reasons; }actively swapping out ($SWAPOUT_RATE pages/s)"
  [ "$SWAP_TREND" = growing ] && reasons="${reasons:+$reasons; }swap $(fmt_mb_signed "$SWAP_DELTA_MB") in ${SWAP_SPAN_MIN}m"

  if [ "$CRIT_STREAK" -ge "$S" ]; then VERDICT="CRITICAL"; reasons="sustained ($CRIT_STREAK samples): $reasons"
  elif [ "$PRESS_STREAK" -ge "$S" ] || [ "$SWAPACT_STREAK" -ge "$S" ]; then VERDICT="HIGH"; reasons="sustained: $reasons"
  elif [ "$elevated" = 1 ] || [ "$swapping" = 1 ]; then VERDICT="WATCH"
  else
    VERDICT="OK"
    reasons="memory pressure $(pressure_text)${FREE_PCT:+, macOS free estimate $FREE_PCT%}, no heavy swap-out"
  fi
  [ -z "${PRESS_LEVEL:-}" ] && [ -z "$FREE_PCT" ] && { VERDICT="UNKNOWN"; reasons="memory pressure could not be read"; }
  VERDICT_REASON=$reasons
}

# One monitoring cycle (live and work mode).
monitor_tick() {   # fast|precise
  local now; now=$(now_epoch)
  collect_memory; collect_pressure; collect_swap
  collect_procs "${1:-fast}"
  now=$(now_epoch)
  update_rates "$now"
  [ $((now - DISK_TS)) -ge "$DISK_INTERVAL" ] && collect_disk
  [ $((now - BATT_TS)) -ge 60 ] && collect_battery
  collect_load
  update_swap_trend "$now"
  update_cpu_streaks
  evaluate_state
  record_history "$now"
  TICKS=$((TICKS + 1))
}

# Full one-shot measurement for diagnostics/report: two memory samples to get a
# real swap-in/out rate, plus precise per-process data.
snapshot_once() {   # fast|precise
  init_monitor_state
  local now; now=$(now_epoch)
  seed_swap_history "$now"
  collect_memory; update_rates "$now"
  collect_pressure; collect_swap; collect_disk; collect_battery; collect_uptime; collect_load
  if [ "${1:-precise}" = precise ]; then collect_procs precise; else collect_procs fast; fi
  now=$(now_epoch)
  if [ "$now" -le "$PREV_TS" ]; then sleep 1; now=$(now_epoch); fi
  collect_memory; update_rates "$now"
  update_swap_trend "$now"
  update_cpu_streaks
  evaluate_state
  record_history "$now"
}

emit_event() {   # level message [notify]
  local ts; ts=$(date '+%H:%M:%S')
  log_event "$1" "$2"
  EVENT_LINES="${EVENT_LINES}${EVENT_LINES:+$NL}[$ts] $1: $2"
  RECENT_EVENTS=$(printf '%s\n%s\n' "$RECENT_EVENTS" "[$ts] $1: $2" | awk 'NF' | tail -n 3)
  [ "${3:-}" = notify ] && notify "$2"
}

notify() {
  [ "$NOTIFICATIONS_ENABLED" = true ] && [ "$HAVE_OSASCRIPT" = 1 ] && [ "$OS_NAME" = Darwin ] || return 0
  local now; now=$(now_epoch)
  [ $((now - LAST_NOTIFY_TS)) -ge $((NOTIFY_COOLDOWN_MIN * 60)) ] || return 0
  LAST_NOTIFY_TS=$now
  run_with_timeout 5 osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' "Mac Performance Manager" "$1" >/dev/null 2>&1
}

process_events() {
  local now S=$SUSTAINED_SAMPLES pid cnt name cpu
  now=$(now_epoch)
  if [ "$VERDICT" != "$PREV_VERDICT" ]; then
    case $VERDICT in
      HIGH|CRITICAL) emit_event WARN "Memory status $VERDICT - $VERDICT_REASON" notify ;;
      OK) case $PREV_VERDICT in HIGH|CRITICAL) emit_event INFO "Memory status back to OK" ;; esac ;;
    esac
    PREV_VERDICT=$VERDICT
  fi
  if [ "$SWAP_TREND" = growing ] && [ "$MEM_ELEVATED" = 1 ] && [ $((now - LAST_SWAPWARN_TS)) -ge $((NOTIFY_COOLDOWN_MIN * 60)) ]; then
    LAST_SWAPWARN_TS=$now
    emit_event WARN "Swap grew $(fmt_mb_signed "$SWAP_DELTA_MB") in ${SWAP_SPAN_MIN}m while memory pressure is elevated" notify
  fi
  if [ -n "$CPU_STREAKS" ]; then
    while IFS="$TAB" read -r pid cnt name cpu; do
      [ "$cnt" = "$S" ] && emit_event WARN "PID $pid ($name) above ${CPU_PROC_WARN_PCT}% CPU for $S consecutive samples (now ${cpu}%)"
    done <<EOF
$CPU_STREAKS
EOF
  fi
  [ "$CPU_TOTAL_STREAK" = "$S" ] && emit_event WARN "Total CPU above ${CPU_TOTAL_WARN_PCT}% for $S consecutive samples"
  if [ "$DISK_STATE" != "$PREV_DISK_STATE" ]; then
    case $DISK_STATE in
      LOW|CRITICAL) emit_event WARN "Disk free space $DISK_STATE: $(fmt_mb "$DISK_AVAIL_MB") free" notify ;;
      OK) [ -n "$PREV_DISK_STATE" ] && [ "$PREV_DISK_STATE" != UNKNOWN ] && emit_event INFO "Disk free space OK again" ;;
    esac
    PREV_DISK_STATE=$DISK_STATE
  fi
}

# =============================================================================
# Recommendations (only from measured data)
# =============================================================================
advice_for_group() {   # app cat count mem_mb
  local app=$1 cat=$2 cnt=$3 mem; mem=$(fmt_mb "$4")
  case $cat in
    Cursor) echo "Cursor: ~$mem across $cnt processes. Close Cursor windows/workspaces you are not using (each has its own renderer and extension host). Find a heavy extension host with Help > Open Process Explorer (menu 7)." ;;
    Brave) echo "Brave: ~$mem across $cnt processes. Close unused tabs; Shift+Esc opens Brave's Task Manager to find heavy tabs; enable Memory Saver in Brave settings if available." ;;
    ChatGPT) echo "ChatGPT app: ~$mem. Quit it while you are not using it (menu 10 > Quit app gracefully)." ;;
    Docker|VM) echo "$app: ~$mem. Stop containers you do not need (docker stop NAME) or quit Docker Desktop; you can lower its memory limit in Docker Settings > Resources." ;;
    Node.js|Python|"JS runtime") echo "$app: $cnt processes using ~$mem. Check menu 8 for dev servers, watchers or agents you no longer need." ;;
    Database) echo "$app (database): ~$mem. Stop it via its own tool (brew services stop / docker stop) if you are not using it now." ;;
    "Local AI") echo "$app (local AI model runtime): ~$mem. A loaded model holds that memory even when idle, out of $(fmt_mb "$MEM_TOTAL_MB") RAM in total; unload it when idle (e.g. ollama stop MODEL)." ;;
    App) echo "$app: ~$mem across $cnt processes. Quit it if you are not actively using it (menu 10 > Quit app gracefully)." ;;
    *) echo "$app: ~$mem across $cnt processes. Investigate if this is unexpected." ;;
  esac
}

build_recommendations() {
  local any=0 heavy_mb line app cat cnt mem rss cpu pid name listed
  # APP_HEAVY_PCT of RAM, capped at APP_HEAVY_CAP_MB: on a 64-128 GB Mac 10% would be 6-13 GB,
  # and pressure there is usually several 2-5 GB apps, none of which would be named.
  heavy_mb=$((MEM_TOTAL_MB * APP_HEAVY_PCT / 100))
  [ "$heavy_mb" -gt "$APP_HEAVY_CAP_MB" ] && heavy_mb=$APP_HEAVY_CAP_MB
  case $VERDICT in
    HIGH|CRITICAL|WATCH)
      [ "$VERDICT" = WATCH ] && echo "- Memory is getting tight (not yet sustained). If the Mac feels slow, start with the largest consumers below."
      [ "$VERDICT" != WATCH ] && echo "- Memory is under sustained pressure. Save your work, then reduce load starting with the largest consumers:"
      [ "$PROC_MEM_SRC" = FOOTPRINT ] || echo "  (sizes are resident memory only: compressed and swapped-out memory is not counted, so real use is higher)"
      any=1
      # Groups above the cutoff; if none reaches it, still name the 3 largest (never an empty list).
      listed=$(group_totals | head -n 8 | awk -F'\t' -v h="$heavy_mb" '
        $1 != "" && $2 != "System" { n++; r[n] = $0; if (int($4 / 1024) >= h) big++ }
        END { for (i = 1; i <= n; i++) { split(r[i], f, "\t"); if (big ? int(f[4] / 1024) >= h : i <= 3) print r[i] } }')
      while IFS="$TAB" read -r app cat cnt mem rss cpu; do
        [ -n "$app" ] || continue
        echo "  * $(advice_for_group "$app" "$cat" "$cnt" $((mem / 1024)))"
      done <<EOF
$listed
EOF
      ;;
  esac
  if [ "$SWAP_TREND" = growing ] && [ "$MEM_ELEVATED" = 1 ]; then
    echo "- Swap grew $(fmt_mb_signed "$SWAP_DELTA_MB") in ${SWAP_SPAN_MIN}m while pressure is elevated: the workload is larger than RAM. Close something before opening more projects/tabs."
    any=1
  fi
  if [ -n "$SUSTAINED_CPU" ]; then
    while IFS="$TAB" read -r pid cnt name cpu; do
      [ -n "$pid" ] || continue
      echo "- PID $pid ($name) has been at/above ${CPU_PROC_WARN_PCT}% CPU for $cnt samples (now ${cpu}%). Check whether this is expected work (build, indexing, tests); if not, investigate it (menu 10)."
      any=1
    done <<EOF
$SUSTAINED_CPU
EOF
  elif [ "$TICKS" -le 1 ]; then
    line=$(printf '%s\n' "$PROCS" | awk -F'\t' -v t="$CPU_PROC_WARN_PCT" -v self="$$" 'NF >= 12 && $1 != self && $5 + 0 >= t { printf "PID %s (%s) %.0f%%; ", $1, $10, $5 }')
    if [ -n "$line" ]; then echo "- High CPU right now (single sample, may be temporary): ${line%; }."; any=1; fi
  fi
  if [ "$CPU_TOTAL_STREAK" -ge "$SUSTAINED_SAMPLES" ]; then
    echo "- Total CPU has stayed above ${CPU_TOTAL_WARN_PCT}% for $CPU_TOTAL_STREAK samples; expect fans/heat and slower response. See menu 3."; any=1
  fi
  if [ "$SWAP_OK" = 1 ] && [ "$SWAP_USED_MB" -ge "$MEM_TOTAL_MB" ] && [ "$VERDICT" != OK ]; then
    echo "- Swap in use is large ($(fmt_mb "$SWAP_USED_MB")). After you close heavy apps macOS frees swap gradually. If slowness persists, save work and restart the heaviest app, or restart the Mac at a convenient time (this tool never restarts anything)."
    any=1
  fi
  case $DISK_STATE in
    LOW|CRITICAL) echo "- Only $(fmt_mb "$DISK_AVAIL_MB") free on the startup disk. Swap files and builds need free space; keep at least ${DISK_FREE_WARN_GB} GB free (menu 4 for targeted scans)."; any=1 ;;
  esac
  if [ "$any" = 0 ]; then
    echo "- No action needed right now."
    [ "$SWAP_OK" = 1 ] && [ "$SWAP_USED_MB" -gt 0 ] &&
      echo "- Existing swap ($(fmt_mb "$SWAP_USED_MB")) with normal pressure and no active swap-out is not a problem by itself."
  fi
}

# =============================================================================
# Views
# =============================================================================
system_line() {
  local batt="" cores="$NCPU cores"
  [ -n "$PCORES" ] && [ -n "$ECORES" ] && cores="$NCPU cores (${PCORES}P+${ECORES}E)"
  if [ -n "$BATT_PCT" ] && [ "$BATT_PCT" != "-" ]; then batt=" | Battery $BATT_PCT% $BATT_STATE, on $BATT_SRC"
  elif [ -n "$BATT_SRC" ] && [ "$BATT_SRC" != unknown ]; then batt=" | Power: $BATT_SRC"; fi
  printf '%s (%s) | %s %s | macOS %s%s | %s | up %s%s\n' "${MODEL_NAME:-Mac}" "${HW_MODEL:-?}" "${CPU_BRAND:-CPU}" "$cores" \
    "$MACOS_VERSION" "${MACOS_BUILD:+ ($MACOS_BUILD)}" "$ARCH" "$(fmt_duration "${UPTIME_SEC:-}")" "$batt"
  [ "$TRANSLATED" = 1 ] && note "Note: this shell runs under Rosetta; architecture shows x86_64 but the Mac is Apple Silicon."
  return 0
}

render_memory_brief() {
  if [ "$MEM_OK" != 1 ]; then echo "  Memory statistics unavailable (vm_stat failed)."; return; fi
  local fp=""; [ -n "$FREE_PCT" ] && fp=" | macOS free estimate $FREE_PCT% (~$(fmt_mb "$MEM_AVAIL_EST_MB"))"
  printf '  RAM %s | pressure %s (kernel level %s)%s\n' "$(fmt_mb "$MEM_TOTAL_MB")" "$(pressure_text)" "${PRESS_LEVEL:-?}" "$fp"
  [ -n "$FREE_PCT" ] && printf '  Available %s %s%%\n' "$(bar "$FREE_PCT" 30)" "$FREE_PCT"
  printf '  Used %s = app %s + wired %s + compressed %s | cached files %s (reclaimable)\n' \
    "$(fmt_mb "$MEM_USED_MB")" "$(fmt_mb "$MEM_APP_MB")" "$(fmt_mb "$MEM_WIRED_MB")" "$(fmt_mb "$MEM_COMP_MB")" "$(fmt_mb "$MEM_CACHED_MB")"
  if [ "$SWAP_OK" = 1 ]; then
    printf '  Swap %s used of %s (%s free) | trend: %s | swap I/O: in %s, out %s pages/s\n' \
      "$(fmt_mb "$SWAP_USED_MB")" "$(fmt_mb "$SWAP_TOTAL_MB")" "$(fmt_mb "$SWAP_FREE_MB")" "$(swap_trend_text)" "${SWAPIN_RATE:-?}" "${SWAPOUT_RATE:-?}"
  else
    echo "  Swap usage unavailable."
  fi
}

render_cpu_brief() {
  local src="ps average"; [ "$CPU_SRC" = top ] && src="1 s sample: user ${CPU_USER}% sys ${CPU_SYS}%"
  printf '  CPU ~%s%% busy (%s) | load %s %s %s on %s cores\n' "$CPU_TOTAL_PCT" "$src" "${LOAD1:-?}" "${LOAD5:-?}" "${LOAD15:-?}" "$NCPU"
}

render_disk_brief() {
  if [ "$DISK_OK" != 1 ]; then echo "  Disk statistics unavailable."; return; fi
  printf '  %s free of %s (%s%% used) %s  %s\n' "$(fmt_mb "$DISK_AVAIL_MB")" "$(fmt_mb "$DISK_TOTAL_MB")" "$DISK_USED_PCT" "$(bar "$DISK_USED_PCT" 20)" "$(badge "$DISK_STATE")"
}

mem_label() { if [ "$PROC_MEM_SRC" = FOOTPRINT ]; then echo "MEM MB"; else echo "RSS MB"; fi; }

print_proc_table() {   # mem|cpu N
  local field=6 n=${2:-10}
  [ "$1" = cpu ] && field=5
  [ -n "$PROCS" ] || { echo "  Process list unavailable."; return; }
  printf '%s\n' "$PROCS" | sort -t "$TAB" -k"$field","$field"nr | head -n "$n" | awk -F'\t' -v fp="$PROC_MEM_SRC" -v ml="$(mem_label)" '
    BEGIN { printf "  %7s %8s %6s  %-9s %-34s %s\n", "PID", ml, "CPU%", "GROUP", "PROCESS", "STARTED BY" }
    NF >= 12 { name = $10; if (length(name) > 34) name = substr(name, 1, 31) "..."
      g = ($9 == "App") ? $8 : (($9 == "Other") ? "-" : $9)
      flag = (fp == "FOOTPRINT" && $7 == "R") ? "*" : " "
      printf "  %7s %7.0f%s %6.1f  %-9s %-34s %s\n", $1, $6 / 1024, flag, $5, substr(g, 1, 9), name, ($11 == "-" ? "" : $11) }'
}

print_group_table() {   # N
  local n=${1:-10}
  group_totals | head -n "$n" | awk -F'\t' -v ml="$(mem_label)" '
    BEGIN { printf "  %-26s %-9s %5s %10s %7s\n", "APPLICATION / GROUP", "TYPE", "PROCS", "SUM " ml, "CPU%" }
    { printf "  %-26s %-9s %5d %10.0f %7.1f\n", substr($1, 1, 26), substr($2, 1, 9), $3, $4 / 1024, $6 }'
}

memory_sum_note() {
  if [ "$PROC_MEM_SRC" = FOOTPRINT ]; then
    note "  MEM = physical footprint from top (what Activity Monitor shows); * = RSS fallback where top had no value."
    note "  Group sums add per-process footprints: closer to reality than RSS, but still an approximation."
  else
    note "  RSS = resident memory from ps. Summing RSS double-counts memory shared between processes"
    note "  (Chromium/Electron helpers share a lot), so group totals are an upper-bound estimate."
  fi
}

render_dev_brief() {
  printf '  Cursor: %s procs (renderers %s, plugin/ext-host %s), ~%s | Node.js %s (~%s) | Python %s (~%s)\n' \
    "$SUM_CUR_N" "$SUM_CUR_REND" "$SUM_CUR_PLUG" "$(fmt_mb "$SUM_CUR_MEM")" "$SUM_NODE_N" "$(fmt_mb "$SUM_NODE_MEM")" "$SUM_PY_N" "$(fmt_mb "$SUM_PY_MEM")"
  printf '  Brave: %s procs (~%s) | Docker/VM processes: %s (~%s)' "$SUM_BRAVE_N" "$(fmt_mb "$SUM_BRAVE_MEM")" "$SUM_DOCK_N" "$(fmt_mb "$SUM_DOCK_MEM")"
  [ "$SUM_AI_N" -gt 0 ] && printf ' | Local AI: %s (~%s)' "$SUM_AI_N" "$(fmt_mb "$SUM_AI_MEM")"
  printf '\n'
}

render_overview() {
  printf '%sMac Performance Manager %s%s   %s\n' "$C_B" "$MPM_VERSION" "$C_RST" "$(date '+%Y-%m-%d %H:%M:%S')"
  system_line
  printf 'Status: %s %s\n' "$(badge "$VERDICT")" "$VERDICT_REASON"
  section "MEMORY"; render_memory_brief
  section "CPU"; render_cpu_brief
  section "DISK (startup volume)"; render_disk_brief
  section "TOP MEMORY"; print_proc_table mem 6
  section "TOP CPU"; print_proc_table cpu 5
  section "DEVELOPMENT"; render_dev_brief
  if [ -n "$RECENT_EVENTS" ]; then section "RECENT EVENTS"; printf '%s\n' "$RECENT_EVENTS" | sed 's/^/  /'; fi
  section "RECOMMENDATIONS"; build_recommendations | awk 'NR <= 8'
}

view_memory() {
  info "Measuring (about 2 seconds)..."
  snapshot_once precise
  section "MEMORY DIAGNOSTICS"
  render_memory_brief
  printf '  Status: %s %s\n' "$(badge "$VERDICT")" "$VERDICT_REASON"
  note "  (One measurement. Sustained detection needs live mode or --work.)"
  section "WHAT THE NUMBERS MEAN"
  cat <<'EOF'
  Memory pressure  macOS's own judgment (normal / warning / critical). It is the best
                   single indicator of whether RAM is the bottleneck.
  Free estimate    kern.memorystatus_level: how much memory macOS considers available
                   (free + easily reclaimable). Full-looking RAM is normal and good.
  App / wired      Process memory / memory the kernel must keep resident.
  Compressed       RAM used by the compressor; it holds more data than its size.
  Cached files     File cache; reclaimed instantly when apps need RAM.
  Swap used        Data written to disk. Existing swap is not a problem by itself;
                   active swap-OUT under pressure is what makes the Mac sluggish.
EOF
  if [ "$MEM_COMP_MB" -gt 0 ]; then
    printf '  Compressor: %s of data stored in %s (%s.%sx)\n' "$(fmt_mb "$MEM_STORED_MB")" "$(fmt_mb "$MEM_COMP_MB")" $((COMP_RATIO_X10 / 10)) $((COMP_RATIO_X10 % 10))
  fi
  section "SWAP HISTORY"; swap_history_summary
  section "LARGEST APPLICATIONS (grouped)"; print_group_table 10; memory_sum_note
  section "RECOMMENDATIONS"; build_recommendations
}

view_cpu() {
  info "Sampling CPU (about 5 seconds)..."
  init_monitor_state
  collect_load
  local i=1
  while [ "$i" -le 3 ]; do
    collect_procs fast; update_cpu_streaks
    [ "$i" -lt 3 ] && sleep 2
    i=$((i + 1))
  done
  local repeated=$SUSTAINED_CPU
  collect_procs precise
  section "CPU DIAGNOSTICS"
  render_cpu_brief
  if [ -n "$LOAD1" ]; then
    awk -v l="$LOAD1" -v n="$NCPU" 'BEGIN { if (l + 0 > n + 0) printf "  Load average (%s) is above the core count (%s): work is queueing for CPU.\n", l, n;
      else printf "  Load average (%s) is within the core count (%s).\n", l, n }'
  fi
  section "TOP CPU (1 s sample)"; print_proc_table cpu 10
  section "CONSISTENTLY BUSY (>= ${CPU_PROC_WARN_PCT}% in 3 samples over ~4 s)"
  if [ -n "$repeated" ]; then
    printf '%s\n' "$repeated" | awk -F'\t' '{ printf "  PID %-7s %-34s last %s%%\n", $1, substr($3, 1, 34), $4 }'
  else
    echo "  None."
  fi
  section "CPU BY APPLICATION"
  group_totals | sort -t "$TAB" -k6,6nr | head -n 8 | awk -F'\t' '$6 > 0 { printf "  %-26s %7.1f%% CPU  (%d procs)\n", substr($1, 1, 26), $6, $3 }'
  note "  CPU% is per core (100% = one full core; this Mac has $NCPU). CPU and memory are separate:"
  note "  a process can hold lots of RAM while idle, or burn CPU with little RAM."
}

swap_history_summary() {
  if [ "$DIRS_OK" != 1 ] || [ ! -f "$HISTORY_FILE" ]; then
    echo "  No history yet (recorded every ${HISTORY_INTERVAL_SEC}s while live or work mode runs)."
    return
  fi
  local now; now=$(now_epoch)
  tail -n 5000 "$HISTORY_FILE" | awk -F'\t' -v now="$now" -v cur="$SWAP_USED_MB" '
    function h(mb) { return (mb >= 1024 || mb <= -1024) ? sprintf("%.1f GB", mb / 1024) : sprintf("%d MB", mb) }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      for (k = 1; k <= 4; k++) { off = (k == 1) ? 900 : (k == 2) ? 3600 : (k == 3) ? 21600 : 86400
        d = $1 - (now - off); if (d < 0) d = -d
        if (d <= off / 4 && (!(k in best) || d < best[k])) { best[k] = d; val[k] = $2 } } }
    END { any = 0
      for (k = 1; k <= 4; k++) if (k in val) { lab = (k == 1) ? "15 min" : (k == 2) ? "1 hour" : (k == 3) ? "6 hours" : "24 hours"
        printf "  %-9s ago: %-9s (change since: %s%s)\n", lab, h(val[k]), (cur - val[k] >= 0 ? "+" : ""), h(cur - val[k]); any = 1 }
      if (!any) print "  Not enough history yet." }'
}

view_top_memory() {
  info "Measuring..."; snapshot_once precise
  section "TOP $TOP_N PROCESSES BY MEMORY"; print_proc_table mem "$TOP_N"
  section "GROUPED BY APPLICATION"; print_group_table 12
  memory_sum_note
}

view_top_cpu() {
  info "Measuring..."; snapshot_once precise
  section "TOP $TOP_N PROCESSES BY CPU (1 s sample)"; print_proc_table cpu "$TOP_N"
  note "  CPU% is per core; 100% = one full core."
}

# --- Cursor -------------------------------------------------------------------
cursor_roles() {   # prints pid \t role  (reads only role flags from args; args are never shown/stored)
  local pids
  pids=$(printf '%s\n' "$PROCS" | awk -F'\t' '$9 == "Cursor" && ($12 == "plugin" || $12 == "utility") { printf "%s%s", sep, $1; sep = "," }')
  [ -n "$pids" ] || return 0
  ps -o pid=,args= -p "$pids" 2>/dev/null | awk '
    { low = tolower($0); r = ""
      if (low ~ /extensionhost|extension-host|extension_host/) r = "extension host"
      else if (low ~ /ptyhost|pty-host/) r = "terminal backend (pty host)"
      else if (low ~ /filewatcher|file-watcher|watcherservice/) r = "file watcher"
      else if (low ~ /sharedprocess|shared-process/) r = "shared process"
      else if (low ~ /utility-sub-type=network/) r = "network service"
      else if (low ~ /utility-sub-type=storage/) r = "storage service"
      else if (low ~ /utility-sub-type=audio/) r = "audio service"
      else if (low ~ /nodeservice/) r = "node utility (ext host / pty / watcher)"
      else if (low ~ /--type=utility/) r = "utility service"
      if (r != "") printf "%s\t%s\n", $1, r }'
}

cursor_extensions() {
  local d="$HOME/.cursor/extensions"
  [ -d "$d" ] || return 1
  ls -1 "$d" 2>/dev/null | awk '/^[^.]/ && $0 != "extensions.json" { n = $0; sub(/-[0-9]+\.[0-9]+.*$/, "", n); print tolower(n) }' | sort -u
}

view_cursor() {
  info "Measuring..."; snapshot_once precise
  section "CURSOR DIAGNOSTICS"
  if [ "$SUM_CUR_N" -eq 0 ]; then
    echo "  Cursor is not running."
  else
    local roles; roles=$(cursor_roles)
    printf '%s\n' "$PROCS" | awk -F'\t' '$9 == "Cursor" { n[$12]++; m += $6; r += $4 }
      END { printf "  Main app processes: %d   Renderers: %d   Plugin helpers: %d   GPU: %d   Utility: %d   Bundled tools: %d\n", n["main"], n["renderer"], n["plugin"], n["gpu"], n["utility"], n["tool"]
            printf "  Sum of Cursor process memory: %.0f MB (RSS sum %.0f MB) - approximate, see note below\n", m / 1024, r / 1024 }'
    echo "  Windows: not exactly detectable from the OS. Renderer count is an upper bound"
    echo "  (each window has one; webviews/panels can add more)."
    [ "$SUM_CUR_MAIN" -gt 1 ] && echo "  ! $SUM_CUR_MAIN main Cursor processes: more than one Cursor instance is running."

    section "CURSOR PROCESSES (by memory)"
    { printf '%s\n' "$roles"; echo '#P'; printf '%s\n' "$PROCS"; } | awk -F'\t' -v ml="$(mem_label)" '
      $0 == "#P" { p = 1; next }
      !p && NF == 2 { role[$1] = $2; next }
      p && $9 == "Cursor" { r = ($1 in role) ? role[$1] : $12; if (r == "plugin") r = "plugin helper (usually an extension host)"
        if (r == "tool") r = "bundled tool: " $10
        printf "%s\t%.0f\t%.1f\t%s\n", $1, $6 / 1024, $5, r }' | sort -t "$TAB" -k2,2nr | head -n 15 |
      awk -F'\t' -v ml="$(mem_label)" 'BEGIN { printf "  %7s %8s %6s  %s\n", "PID", ml, "CPU%", "ROLE" } { printf "  %7s %8s %6s  %s\n", $1, $2, $3, $4 }'

    section "PROCESSES STARTED BY CURSOR (language servers, terminals, agents, dev servers)"
    printf '%s\n' "$PROCS" | awk -F'\t' '$11 == "Cursor" { k = $10; n[k]++; m[k] += $6; c[k] += $5; tn++; tm += $6 }
      END { if (!tn) { print "  None."; exit } for (k in n) printf "%d\t%s\t%d\t%.1f\n", m[k] / 1024, k, n[k], c[k] }' |
      sort -t "$TAB" -k1,1nr | head -n 12 | awk -F'\t' 'NF == 4 { printf "  %-30s x%-3d %7d MB %6.1f%% CPU\n", substr($2, 1, 30), $3, $1, $4 } NF != 4 { print }'
  fi

  section "EXTENSIONS"
  local exts ai
  if exts=$(cursor_extensions); then
    printf '  Installed: %s (folder ~/.cursor/extensions)\n' "$(printf '%s\n' "$exts" | awk 'NF' | wc -l | tr -d ' ')"
    ai=$(printf '%s\n' "$exts" | awk '/copilot|^continue\.|codeium|tabnine|cody|amazon-q|aws-toolkit|supermaven|claude-dev|roo-cline|claude-code|openai\.chatgpt|gemini|blackbox|codegpt|kilo-code|augment|qodo|codium|aider|bito|windsurf/')
    if [ -n "$ai" ]; then
      echo "  AI assistants installed in addition to Cursor's built-in AI:"
      printf '%s\n' "$ai" | sed 's/^/    - /'
      echo "  Each can run its own background services and indexing. Consider disabling those you"
      echo "  do not use (Extensions view > Disable, or Disable (Workspace)). Nothing is changed automatically."
    else
      echo "  No additional AI-assistant extensions detected."
    fi
  else
    echo "  Extension folder not found (~/.cursor/extensions)."
  fi

  section "FINDINGS"
  local found=0
  if [ "$SUM_CUR_N" -gt 0 ]; then
    [ "$SUM_CUR_PLUG" -gt 2 ] && { echo "  - $SUM_CUR_PLUG plugin helpers (usually one extension host per window): close windows you are not using."; found=1; }
    printf '%s\n' "$PROCS" | awk -F'\t' -v t="$CPU_PROC_WARN_PCT" '($9 == "Cursor" || $11 == "Cursor") && $5 + 0 >= t { printf "  - PID %s (%s) uses %.0f%% CPU now: check Process Explorer to see what it is.\n", $1, $10, $5; f = 1 } END { exit !f }' && found=1
    printf '%s\n' "$PROCS" | awk -F'\t' '$11 == "Cursor" && $10 == "node" && $6 > 1048576 { printf "  - PID %s: a Node process started by Cursor uses %.1f GB (often tsserver/eslint). Try \"TypeScript: Restart TS Server\" and exclude big folders in tsconfig.\n", $1, $6 / 1048576; f = 1 } END { exit !f }' && found=1
    [ "$SUM_CUR_MEM" -gt $((MEM_TOTAL_MB * 40 / 100)) ] && { echo "  - Cursor uses ~$(fmt_mb "$SUM_CUR_MEM") (over 40% of RAM). Fewer open windows/workspaces is the most effective fix."; found=1; }
  fi
  [ "$found" = 0 ] && echo "  Nothing unusual measured."

  section "HOW TO DIG DEEPER INSIDE CURSOR"
  cat <<'EOF'
  1. Process Explorer: Help > Open Process Explorer (or Cmd+Shift+P "Developer: Open
     Process Explorer"). Shows CPU/memory per window, extension host and language server.
  2. Running extensions: Cmd+Shift+P "Developer: Show Running Extensions". Shows activation
     time and lets you record an extension-host CPU profile. Activation time alone does
     not mean an extension uses a lot of RAM.
  3. "Developer: Restart Extension Host" resets a misbehaving extension host without
     closing your windows.
  4. "Help: Start Extension Bisect" finds a problematic extension by halving the set.
  5. Disable per project: Extensions view > gear > "Disable (Workspace)".
  6. Reduce indexing/watching: settings files.watcherExclude and search.exclude
     (node_modules, dist, .venv, build output) and a .cursorignore file.
  LIMITATION: macOS cannot attribute memory to individual extensions. All extensions of
  a window share one extension-host process, so only Cursor's own tools can split it.
EOF
  memory_sum_note
  if [ "$SUM_CUR_N" -gt 0 ] && is_tty && [ "$OS_NAME" = Darwin ]; then
    if ask "Bring Cursor to the front now so you can open Process Explorer? [y/N] "; then
      case $REPLY_VAL in y|Y) open -a Cursor 2>/dev/null || warn "could not activate Cursor." ;; esac
    fi
  fi
}

# --- Development --------------------------------------------------------------
list_listeners() {   # -> pid \t ports (only your own processes; no sudo)
  [ "$HAVE_LSOF" = 1 ] || return 1
  run_with_timeout 10 lsof -nP -iTCP -sTCP:LISTEN -Fpcn 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2) }
    /^n/ { port = substr($0, 2); sub(/.*:/, "", port)
      if (port ~ /^[0-9]+$/) { k = pid ":" port; if (!(k in seen)) { seen[k] = 1; if (pid in ports) ports[pid] = ports[pid] "," port; else ports[pid] = port } } }
    END { for (p in ports) printf "%s\t%s\n", p, ports[p] }'
}

proc_cwd() {
  [ "$HAVE_LSOF" = 1 ] || return 0
  run_with_timeout 5 lsof -a -p "$1" -d cwd -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }'
}

proc_etime() { ps -o etime= -p "$1" 2>/dev/null | awk '{ print $1 }'; }

docker_ready() {
  [ "$HAVE_DOCKER" = 1 ] || return 1
  run_with_timeout 6 docker info --format '{{.ServerVersion}}' >/dev/null 2>&1
}

view_docker() {
  if [ "$HAVE_DOCKER" != 1 ]; then echo "  Docker CLI not installed."; return; fi
  if ! docker_ready; then echo "  Docker is installed but its engine is not running (or did not answer in 6 s)."; return; fi
  local out
  out=$(run_with_timeout 15 docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | awk -F'\t' 'BEGIN { printf "  %-30s %8s  %s\n", "CONTAINER", "CPU", "MEMORY (used / limit)" } { printf "  %-30s %8s  %s\n", substr($1, 1, 30), $2, $3 }'
  else
    echo "  No running containers."
  fi
  echo "  Stop one you do not need with: docker stop NAME   (this tool will not do it for you)."
  note "  Docker Desktop runs containers inside a VM; that VM's memory shows as Docker/VM processes."
}

view_dev() {
  info "Measuring..."; snapshot_once precise
  section "RUNTIMES"
  printf '%s\n' "$PROCS" | awk -F'\t' '$9 ~ /^(Node.js|Python|JS runtime|Database|Local AI|Docker|VM)$/ { k = $9; n[k]++; m[k] += $6; by[k, ($11 == "-" ? "other" : $11)]++ }
    END { for (k in n) { s = ""; for (kk in by) { split(kk, a, SUBSEP); if (a[1] == k) s = s (s ? ", " : "") by[kk] " via " a[2] }
      printf "  %-11s %3d processes  ~%6.0f MB  (%s)\n", k, n[k], m[k] / 1024, s } }' | sort
  [ "$SUM_NODE_N$SUM_PY_N" = "00" ] && echo "  No Node.js or Python processes."

  section "LISTENING SERVERS (your processes)"
  local l
  if l=$(list_listeners) && [ -n "$l" ]; then
    printf '  %7s %-14s %-22s %8s %6s %-11s %s\n' PID "PORT(S)" PROCESS "MEM MB" "CPU%" UPTIME "PROJECT DIR"
    while IFS="$TAB" read -r pid ports; do
      [ -n "$pid" ] || continue
      local row cwd et
      row=$(printf '%s\n' "$PROCS" | awk -F'\t' -v p="$pid" '$1 == p { printf "%s\t%.0f\t%.1f\t%s", $10, $6 / 1024, $5, $9; exit }')
      [ -n "$row" ] || continue
      cwd=$(tilde_path "$(proc_cwd "$pid")")
      et=$(proc_etime "$pid")
      printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$ports" "$row" "$et" "$cwd"
    done <<EOF
$l
EOF
  else
    echo "  None found (or lsof unavailable)."
  fi | awk -F'\t' 'NF >= 8 { dev = ($6 ~ /^(Node.js|Python|JS runtime|Database|Local AI|Other)$/) ? "" : " (app)"
      printf "  %7s %-14s %-22s %8s %6s %-11s %s%s\n", $1, substr($2, 1, 14), substr($3, 1, 22), $4, $5, $7, $8, dev } NF < 8 { print }'
  note "  CPU% is a recent average: a low value suggests a server is idle now, not that it is unused."

  section "NODE / PYTHON PROCESSES (top 10 by memory; command lines redacted, shown on screen only)"
  local pids
  pids=$(printf '%s\n' "$PROCS" | awk -F'\t' '$9 == "Node.js" || $9 == "Python" || $9 == "JS runtime" { printf "%s\t%s\n", $6, $1 }' | sort -t "$TAB" -k1,1nr | head -n 10 | awk -F'\t' '{ printf "%s%s", s, $2; s = "," }')
  if [ -n "$pids" ]; then
    ps -o pid=,args= -p "$pids" 2>/dev/null | while IFS= read -r line; do
      local p a meta
      p=$(printf '%s' "$line" | awk '{ print $1 }'); a=$(printf '%s' "$line" | sed 's/^ *[0-9]* *//' | redact_args | cut -c1-90)
      meta=$(printf '%s\n' "$PROCS" | awk -F'\t' -v p="$p" '$1 == p { printf "%6.0f MB %5.1f%% via %-8s", $6 / 1024, $5, ($11 == "-" ? "-" : $11); exit }')
      printf '  %7s %s %s\n' "$p" "$meta" "$a"
    done
  else
    echo "  None."
  fi

  section "DOCKER"; view_docker

  section "WORTH INVESTIGATING"
  printf '%s\n' "$PROCS" | awk -F'\t' -v t="$CPU_PROC_WARN_PCT" '
    $9 ~ /^(Node.js|Python|JS runtime|Database|Local AI|Docker|VM)$/ && ($6 > 1048576 || $5 + 0 >= t) {
      printf "  - PID %s %s (%s): %.0f MB, %.0f%% CPU\n", $1, $10, $9, $6 / 1024, $5; f = 1 }
    END { if (!f) print "  Nothing heavy measured among development processes." }'
}

# =============================================================================
# Disk
# =============================================================================
view_disk_overview() {
  collect_disk
  section "STARTUP DISK"
  render_disk_brief
  printf '  Volume: %s\n' "$DISK_TARGET"
  note "  df does not count 'purgeable' space that Finder may include in its 'available' figure."
  case $DISK_STATE in
    LOW|CRITICAL) echo "  Free space is low. macOS needs room for swap files and updates; aim for >= ${DISK_FREE_WARN_GB} GB." ;;
  esac
}

artifact_info() {   # name -> tier|description|risk
  case $1 in
    node_modules) echo "safe|Installed npm/pnpm/yarn packages|Re-run pnpm install / npm install (needs network unless cached)." ;;
    .next|.nuxt|.svelte-kit|.turbo|.parcel-cache|.angular) echo "safe|Framework build cache|Rebuilt automatically; the next build/dev start is slower." ;;
    __pycache__|.pytest_cache|.mypy_cache|.ruff_cache) echo "safe|Python bytecode / tool cache|Regenerated automatically." ;;
    .venv|venv) echo "ignored-only|Python virtual environment|Must be recreated; packages installed by hand and not recorded are lost; running processes using it break." ;;
    dist|build|target|coverage|.gradle|.cache) echo "ignored-only|Build output or tool cache|Some projects commit these, so only offered when Git ignores it." ;;
    *) echo "report|Unknown|Report only." ;;
  esac
}

git_q() { run_with_timeout 10 git -C "$1" "$@" >/dev/null 2>&1; }

# Returns 0 if a scanned path may be offered for moving to Trash; prints the reason otherwise.
artifact_eligible() {   # path root
  local p=$1 root=$2 name parent info tier inrepo=0
  name=$(basename "$p"); parent=$(dirname "$p")
  [ -d "$p" ] || { echo "no longer exists"; return 1; }
  [ -L "$p" ] && { echo "is a symbolic link"; return 1; }
  case $p in "$root"/*) ;; *) echo "outside the scanned folder"; return 1 ;; esac
  [ "$p" = "$HOME" ] || [ "$p" = "/" ] && { echo "protected location"; return 1; }
  info=$(artifact_info "$name"); tier=${info%%|*}
  [ "$tier" = report ] && { echo "unknown kind; report only"; return 1; }
  if [ "$HAVE_GIT" = 1 ] && run_with_timeout 10 git -C "$parent" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    inrepo=1
    if [ -n "$(run_with_timeout 10 git -C "$parent" ls-files -- "$name" 2>/dev/null | head -n 1)" ]; then
      echo "contains files tracked by Git; never offered"; return 1
    fi
  fi
  if [ "$tier" = ignored-only ]; then
    if [ "$inrepo" = 1 ] && run_with_timeout 10 git -C "$parent" check-ignore -q -- "$name" 2>/dev/null; then return 0; fi
    echo "not ignored by Git (or not in a Git repo); report only"; return 1
  fi
  return 0
}

scan_dev_artifacts() {
  [ "$HAVE_FIND" = 1 ] && [ "$HAVE_DU" = 1 ] || { warn "find/du not available."; return; }
  echo "Scan a folder for large, regenerable development artifacts (node_modules, build caches,"
  echo "Python caches, virtualenvs). Nothing is deleted by scanning. Ctrl+C aborts the scan."
  ask "Folder to scan [default: $HOME/Projects if it exists, else $HOME]: " || return
  local root=$REPLY_VAL
  if [ -z "$root" ]; then if [ -d "$HOME/Projects" ]; then root="$HOME/Projects"; else root=$HOME; fi; fi
  case $root in "~") root=$HOME ;; "~/"*) root="$HOME/${root#\~/}" ;; esac
  [ -d "$root" ] || { warn "not a folder: $root"; return; }
  root=$(cd "$root" 2>/dev/null && pwd -P) || { warn "cannot open folder."; return; }
  echo "Scanning $root (max depth $SCAN_MAX_DEPTH)..."
  SCAN_ABORT=0
  trap 'SCAN_ABORT=1' INT
  local found
  found=$(find "$root" -maxdepth "$SCAN_MAX_DEPTH" \( -path "$HOME/Library" -o -path "$HOME/.Trash" -o -name .git \) -prune -o \
    -type d \( -name node_modules -o -name .next -o -name .nuxt -o -name .svelte-kit -o -name .turbo -o -name .parcel-cache \
    -o -name .angular -o -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache -o -name .venv \
    -o -name venv -o -name dist -o -name build -o -name target -o -name coverage -o -name .gradle -o -name .cache \) -prune -print 2>/dev/null)
  SCAN_RESULTS=""
  if [ "$SCAN_ABORT" = 0 ] && [ -n "$found" ]; then
    SCAN_RESULTS=$(printf '%s\n' "$found" | while IFS= read -r p; do
      [ "$SCAN_ABORT" = 1 ] && break
      [ -d "$p" ] || continue
      du -sk "$p" 2>/dev/null | awk -F'\t' 'NR == 1 { print $1 }' | while read -r kb; do printf '%s\t%s\n' "$kb" "$p"; done
    done | sort -t "$TAB" -k1,1nr | head -n 40)
  fi
  trap 'on_signal INT 130' INT
  [ "$SCAN_ABORT" = 1 ] && { warn "scan aborted."; SCAN_RESULTS=""; return; }
  SCAN_ROOT=$root
  show_scan_results
}

show_scan_results() {
  if [ -z "$SCAN_RESULTS" ]; then echo "  No development artifacts found."; return; fi
  section "LARGEST ARTIFACTS IN $SCAN_ROOT"
  local i=0 kb p info
  while IFS="$TAB" read -r kb p; do
    i=$((i + 1)); info=$(artifact_info "$(basename "$p")")
    printf '  %2d) %8s  %-12s %s\n' "$i" "$(fmt_mb $((kb / 1024)))" "${info%%|*}" "$(tilde_path "$p")"
  done <<EOF
$SCAN_RESULTS
EOF
  printf '%s\n' "$SCAN_RESULTS" | awk -F'\t' '{ s += $1 } END { printf "  Total listed: %.1f GB\n", s / 1048576 }'
  note "  safe = regenerated by tools; ignored-only = offered only if Git ignores it. Use 'Move to Trash' to act."
}

trash_path() {   # moves to Trash (reversible). Never deletes permanently.
  local p=$1 dest
  if [ "$HAVE_OSASCRIPT" = 1 ] && [ "$OS_NAME" = Darwin ]; then
    run_with_timeout 60 osascript -e 'on run argv' -e 'set f to (item 1 of argv) as POSIX file' \
      -e 'tell application "Finder" to delete (f as alias)' -e 'end run' "$p" >/dev/null 2>&1
    [ -e "$p" ] || return 0
  fi
  if [ -d "$HOME/.Trash" ] && [ -w "$HOME/.Trash" ]; then
    dest="$HOME/.Trash/$(basename "$p")-mpm-$(date +%Y%m%d-%H%M%S)-$$"
    mv -- "$p" "$dest" 2>/dev/null && return 0
  fi
  return 1
}

trash_artifact_flow() {
  [ -n "$SCAN_RESULTS" ] || { echo "Run a scan first."; return; }
  show_scan_results
  ask "Number to move to Trash (Enter to cancel): " || return
  local n=$REPLY_VAL line kb p name info why id
  is_uint "$n" || return
  line=$(printf '%s\n' "$SCAN_RESULTS" | awk -v n="$n" 'NR == n')
  [ -n "$line" ] || { warn "no such entry."; return; }
  kb=${line%%"$TAB"*}; p=${line#*"$TAB"}; name=$(basename "$p"); info=$(artifact_info "$name")
  section "REVIEW"
  printf '  Path:     %s\n  Size:     %s (approximate)\n  What:     %s\n  Risk:     %s\n' "$p" "$(fmt_mb $((kb / 1024)))" \
    "$(printf '%s' "$info" | cut -d'|' -f2)" "$(printf '%s' "$info" | cut -d'|' -f3)"
  if ! why=$(artifact_eligible "$p" "$SCAN_ROOT"); then
    echo "  Not offered: $why."
    return
  fi
  id=$(stat -f '%d:%i' "$p" 2>/dev/null)   # the folder itself (stat does not follow symlinks)
  echo "  The folder is moved to the Trash (reversible). Space is freed when you empty the Trash."
  ask "Type 'trash' to confirm: " || return
  [ "$REPLY_VAL" = trash ] || { echo "Cancelled. Nothing changed."; return; }
  # Re-check after confirmation: the path may have been replaced (e.g. by a symlink) meanwhile.
  if ! why=$(artifact_eligible "$p" "$SCAN_ROOT"); then echo "Refused: $why since review. Nothing changed."; return; fi
  if [ -z "$id" ] || [ "$(stat -f '%d:%i' "$p" 2>/dev/null)" != "$id" ]; then
    echo "Refused: the folder changed since review. Nothing changed."; return
  fi
  if trash_path "$p"; then
    echo "Moved to Trash: $p"; log_event ACTION "moved a $name folder to Trash ($((kb / 1024)) MB)"
    SCAN_RESULTS=$(printf '%s\n' "$SCAN_RESULTS" | awk -v n="$n" 'NR != n')
  else
    echo "Could not move it to the Trash (Finder automation not allowed, or permission denied)."
    echo "If you still want it gone, remove it yourself after double-checking the path:"
    printf '  rm -rf -- %s\n' "$(shell_quote "$p")"
  fi
}

view_known_caches() {
  [ "$HAVE_DU" = 1 ] || { warn "du not available."; return; }
  echo "Measuring known cache locations (can take a while for big folders)..."
  section "KNOWN CACHE LOCATIONS (report only - nothing is deleted)"
  local entries="$HOME/.npm/_cacache|npm download cache|npm cache verify   (or: npm cache clean --force)
$HOME/Library/pnpm/store|pnpm content store|pnpm store prune   (removes only unreferenced packages)
$HOME/.pnpm-store|pnpm content store|pnpm store prune
$HOME/Library/Caches/Yarn|Yarn cache|yarn cache clean
$HOME/Library/Caches/pip|pip download cache|pip cache purge
$HOME/.cache/uv|uv cache|uv cache prune
$HOME/.cache/huggingface|Hugging Face models/datasets|huggingface-cli delete-cache   (choose interactively)
$HOME/.ollama/models|Ollama local models|ollama list, then: ollama rm MODEL
$HOME/Library/Caches/Homebrew|Homebrew downloads|brew cleanup
$HOME/Library/Developer/Xcode/DerivedData|Xcode build data|Delete inside Xcode or remove the folder; Xcode rebuilds it
$HOME/Library/Developer/CoreSimulator|iOS simulators|xcrun simctl delete unavailable
$HOME/Library/Application Support/Cursor/CachedData|Cursor cached data from old versions|Quit Cursor first; old version folders can be removed
$HOME/Library/Application Support/Cursor/User/workspaceStorage|Cursor per-workspace state|Only remove folders of projects you no longer use, with Cursor quit
$HOME/Library/Application Support/Cursor/logs|Cursor logs|Safe to clear with Cursor quit
$HOME/Library/Containers/com.docker.docker/Data|Docker Desktop disk image|docker system df, then docker image prune / docker builder prune (never volumes unless you are sure)
$HOME/Library/Caches|All app caches (total)|Do not wipe wholesale; apps rebuild caches and get slower meanwhile"
  local path desc how kb
  while IFS='|' read -r path desc how; do
    [ -d "$path" ] || continue
    kb=$(run_with_timeout 60 du -sk "$path" 2>/dev/null | awk '{ print $1; exit }')
    is_uint "$kb" || kb=0
    printf '  %8s  %s\n            %s\n            how: %s\n' "$(fmt_mb $((kb / 1024)))" "$(tilde_path "$path")" "$desc" "$how"
  done <<EOF
$entries
EOF
  note "  Run cleanup commands yourself when you understand their effect. Browser profiles and app data are never touched."
}

view_docker_disk() {
  section "DOCKER DISK USAGE"
  if docker_ready; then
    run_with_timeout 30 docker system df 2>/dev/null | sed 's/^/  /'
    echo "  Reclaim with: docker image prune (dangling images), docker builder prune (build cache)."
    echo "  Volumes contain data (databases!) and are never touched by this tool."
  else
    echo "  Docker not installed or not running."
  fi
}

disk_menu() {
  while :; do
    section "DISK DIAGNOSTICS"
    echo "  1) Startup disk overview"
    echo "  2) Scan a folder for development artifacts (you choose the folder)"
    echo "  3) Move a scanned artifact to Trash (with review + confirmation)"
    echo "  4) Sizes of known caches (npm, pnpm, pip, Xcode, Cursor, Docker...)"
    echo "  5) Docker disk usage"
    echo "  b) Back"
    ask "Select: " || return
    case $REPLY_VAL in
      1) view_disk_overview; pause ;;
      2) scan_dev_artifacts; pause ;;
      3) trash_artifact_flow; pause ;;
      4) view_known_caches; pause ;;
      5) view_docker_disk; pause ;;
      b|B|q|Q|"") return ;;
      *) echo "Unknown choice." ;;
    esac
  done
}

# =============================================================================
# Process actions (always confirmed, never automatic)
# =============================================================================
self_ancestors() {   # pids of this script and every ancestor up to launchd
  local p=$$ out="$$" i=0 pp
  while [ "$i" -lt 64 ]; do
    pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    is_uint "$pp" && [ "$pp" -gt 1 ] || break
    out="$out $pp"; p=$pp; i=$((i + 1))
  done
  echo "$out"
}

is_protected_name() {
  case $1 in
    launchd|kernel_task|loginwindow|WindowServer|Finder|Dock|SystemUIServer|ControlCenter|NotificationCenter|Spotlight|\
    mds|mds_stores|mdworker*|cfprefsd|distnoted|coreaudiod|sharingd|bluetoothd|trustd|securityd|secd|opendirectoryd|\
    UserEventAgent|Terminal|iTerm2|Warp|ssh-agent|gpg-agent|login|sshd|tmux*|screen) return 0 ;;
  esac
  return 1
}

proc_fields() {   # pid -> uid \t ppid \t rss_kb \t cpu \t etime \t comm
  ps -o uid=,ppid=,rss=,%cpu=,etime=,comm= -p "$1" 2>/dev/null | awk 'NF >= 6 { c = $0
    if (!sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[0-9.]+[ \t]+[0-9:-]+[ \t]+/, "", c)) c = ""   # unparsable: no identity
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, c; exit }'
}
proc_identity() { ps -o lstart=,comm= -p "$1" 2>/dev/null | awk '{ $1 = $1; print }'; }

# Shared guard. Sets T_* fields; on refusal sets T_REASON and returns 1.
check_terminable() {   # pid
  local pid=$1 f a
  T_REASON=""
  is_uint "$pid" || { T_REASON="'$pid' is not a PID."; return 1; }
  [ "$pid" -gt 1 ] || { T_REASON="PID $pid is a core system process."; return 1; }
  case " $(self_ancestors) " in *" $pid "*) T_REASON="PID $pid is this manager or the shell/terminal running it."; return 1 ;; esac
  f=$(proc_fields "$pid")
  [ -n "$f" ] || { T_REASON="No process with PID $pid (it may have exited)."; return 1; }
  IFS="$TAB" read -r T_UID T_PPID T_RSS T_CPU T_ETIME T_COMM <<EOF
$f
EOF
  [ -n "$T_COMM" ] || { T_REASON="PID $pid cannot be identified confidently; refusing."; return 1; }
  [ "$T_UID" = "$CURRENT_UID" ] || { T_REASON="PID $pid belongs to another user or the system (uid $T_UID). Refusing (no sudo)."; return 1; }
  case $T_COMM in
    /System/*|/usr/libexec/*|/usr/sbin/*|/sbin/*|/bin/*|/usr/bin/*|/Library/Apple/*)
      T_REASON="$T_COMM is part of macOS. Refusing."; return 1 ;;
  esac
  is_protected_name "${T_COMM##*/}" && { T_REASON="${T_COMM##*/} is critical for your session. Refusing."; return 1; }
  a=$(ps -o args= -p "$pid" 2>/dev/null)
  case $a in *mac-performance-manager*) T_REASON="That is a Mac Performance Manager instance; use menu 12 (Stop monitoring)."; return 1 ;; esac
  return 0
}

terminate_flow() {   # [pid]
  local pid=${1:-} ident kind="other" base args cwd
  T_ACTION=""
  if [ -z "$pid" ]; then
    ask "PID to terminate (Enter to cancel): " || return
    pid=$(trim "$REPLY_VAL")
  fi
  [ -n "$pid" ] || return
  T_ACTION=refused
  if ! check_terminable "$pid"; then echo "Refused: $T_REASON"; return 1; fi
  ident=$(proc_identity "$pid")
  [ -n "$ident" ] || { echo "Refused: PID $pid cannot be identified confidently (start time unreadable)."; return 1; }
  base=${T_COMM##*/}
  case $T_COMM in
    */Cursor.app/*) kind=cursor ;;
    *.app/Contents/MacOS/*) case $T_COMM in *.app/*.app/*) kind=helper ;; *) kind=app ;; esac ;;
  esac
  case $(printf '%s' "$base" | tr 'A-Z' 'a-z') in
    com.docker.*|docker*|vpnkit*|qemu*|postgres*|postmaster|mysqld|mariadbd|mongod|mongos|redis-server|valkey-server|clickhouse*) kind=data ;;
    node|python*|bun|deno|next-server*|next-router-worker*|tsserver*|typingsinstaller*|vite*|webpack*|esbuild*|turbo*|nodemon*|ts-node*|tsx|eslint*) kind=dev ;;
  esac
  args=$(ps -o args= -p "$pid" 2>/dev/null | redact_args | cut -c1-300)
  section "PROCESS TO TERMINATE"
  printf '  Name:     %s\n  PID:      %s (parent %s)\n  CPU:      %s%%\n  Memory:   %s (RSS)\n  Running:  %s\n  Command:  %s\n' \
    "$base" "$pid" "$T_PPID" "$T_CPU" "$(fmt_mb $((T_RSS / 1024)))" "$T_ETIME" "$args"
  if [ "$kind" = dev ]; then cwd=$(proc_cwd "$pid"); [ -n "$cwd" ] && printf '  Folder:   %s\n' "$cwd"; fi
  note "  (Command shown on screen only, with likely secrets redacted; it is never logged.)"
  case $kind in
    cursor) echo "  ! This is part of Cursor. Killing it can crash a window or the extension host and interrupt"
            echo "    running agents. Prefer Cursor's 'Developer: Restart Extension Host' or closing the window." ;;
    app)    echo "  ! This is an application's main process. 'Quit app gracefully' (menu 10 > 2) lets it ask"
            echo "    you to save first. Terminating here sends SIGTERM, which may not prompt to save." ;;
    helper) echo "  ! This is a helper of an application; the app may show an error or reload a window/tab." ;;
    data)   echo "  ! Docker/database process. Stopping it directly can lose in-flight writes. Prefer"
            echo "    'docker stop', 'brew services stop', or the app's own controls." ;;
    dev)    echo "  ! Development process (server, watcher, agent or tool). Make sure it is not doing work you need." ;;
  esac
  echo "  A high memory number alone is not a reason to kill a process."
  ask "Type 'yes' to send SIGTERM (graceful), anything else cancels: " || return
  T_ACTION=cancelled
  [ "$REPLY_VAL" = yes ] || { echo "Cancelled. Nothing was sent."; return 0; }
  [ "$(proc_identity "$pid")" = "$ident" ] || { echo "Refused: PID $pid changed or exited since review."; return 1; }
  kill -TERM "$pid" 2>/dev/null || { echo "Could not signal PID $pid (it may have exited or is protected)."; return 1; }
  T_ACTION=sigterm
  log_event ACTION "sent SIGTERM to PID $pid ($base)"
  local i=0
  printf 'Waiting up to %ss for it to exit' "$KILL_GRACE_SEC"
  while [ "$i" -lt "$KILL_GRACE_SEC" ]; do
    if ! kill -0 "$pid" 2>/dev/null || [ "$(proc_identity "$pid")" != "$ident" ]; then printf '\nPID %s exited.\n' "$pid"; return 0; fi
    printf '.'; sleep 1; i=$((i + 1))
  done
  printf '\nPID %s is still running (it may be saving data or ignoring SIGTERM).\n' "$pid"
  ask "Type 'KILL' to force-stop it with SIGKILL (unsaved data in it is lost), anything else leaves it running: " || return
  [ "$REPLY_VAL" = KILL ] || { echo "Left running."; T_ACTION=left; return 0; }
  [ "$(proc_identity "$pid")" = "$ident" ] || { echo "PID $pid already exited or changed; nothing sent."; return 0; }
  kill -KILL "$pid" 2>/dev/null && { echo "SIGKILL sent to PID $pid."; T_ACTION=sigkill; log_event ACTION "sent SIGKILL to PID $pid ($base)"; }
}

list_gui_apps() {   # -> pid \t app_name \t bundle_name \t group_mem_kb
  printf '%s\n' "$PROCS" | awk -F'\t' -v me="$CURRENT_UID" '
    NF >= 13 { g[$8] += $6 }
    NF >= 13 && $12 == "main" && $3 == me && $9 != "System" && $9 != "Python" {
      t = $13; c = gsub(/\.app\//, "&", t)
      if (c == 1 && $13 ~ /\.app\/Contents\/MacOS\/[^\/]+$/) { b = $13; sub(/\.app\/Contents\/MacOS\/[^\/]+$/, "", b); sub(/.*\//, "", b); line[$8] = $1 "\t" $8 "\t" b }
    }
    END { for (k in line) printf "%s\t%d\n", line[k], g[k] }' | sort -t "$TAB" -k4,4nr
}

quit_app_flow() {
  QA_ACTION=""; QA_NAME=""
  info "Reading running applications..."
  collect_procs fast
  local apps; apps=$(list_gui_apps)
  [ -n "$apps" ] || { echo "No regular applications found."; return; }
  section "RUNNING APPLICATIONS (memory = RSS sum of the app's processes, approximate)"
  printf '%s\n' "$apps" | awk -F'\t' '{ printf "  %2d) %-28s %7.0f MB\n", NR, substr($2, 1, 28), $4 / 1024 }'
  ask "Number of the app to quit (Enter to cancel): " || return
  local n=$REPLY_VAL line pid name bundle
  is_uint "$n" || return
  line=$(printf '%s\n' "$apps" | awk -v n="$n" 'NR == n')
  [ -n "$line" ] || { warn "no such entry."; return; }
  pid=$(printf '%s' "$line" | cut -f1); name=$(printf '%s' "$line" | cut -f2); bundle=$(printf '%s' "$line" | cut -f3)
  quit_app_do "$pid" "$name" "$bundle"
}

# Asks one application to quit normally, after the safety checks and a confirmation.
# Sets QA_ACTION (asked|cancelled|refused|"") and QA_NAME.
quit_app_do() {   # pid app_name bundle_name
  local pid=$1 name=$2 bundle=$3
  QA_ACTION=""; QA_NAME=$bundle
  case " $(self_ancestors) " in *" $pid "*) echo "Refused: $name hosts this manager."; QA_ACTION=refused; return ;; esac
  is_protected_name "$bundle" && { echo "Refused: $bundle is critical for your session."; QA_ACTION=refused; return; }
  [ "$name" = Cursor ] && echo "  Note: quitting Cursor stops its AI agents and terminals; Cursor will ask about unsaved files."
  ask "Ask '$bundle' to quit normally (it can prompt you to save)? [y/N] " || return
  case $REPLY_VAL in y|Y|yes) ;; *) echo "Cancelled."; QA_ACTION=cancelled; return ;; esac
  if [ "$HAVE_OSASCRIPT" = 1 ] && [ "$OS_NAME" = Darwin ]; then
    if run_with_timeout 30 osascript -e 'on run argv' -e 'tell application (item 1 of argv) to quit' -e 'end run' "$bundle" >/dev/null 2>&1; then
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then echo "$bundle is still open: it may be asking you to save. Check its window."
      else echo "$bundle quit."; fi
      log_event ACTION "asked application $bundle to quit"; QA_ACTION=asked
      return
    fi
    echo "macOS did not allow the quit request (System Settings > Privacy & Security > Automation"
    echo "must allow your terminal to control '$bundle'), or the app did not answer."
  fi
  echo "You can quit it yourself with Cmd+Q, or terminate its main process (PID $pid) via menu 10 > 1."
}

process_menu() {
  while :; do
    section "INTERACTIVE PROCESS MANAGEMENT"
    echo "  Nothing here happens without your explicit confirmation."
    echo "  1) Terminate a process by PID (shows details first)"
    echo "  2) Quit an application gracefully"
    echo "  3) Show top memory processes"
    echo "  4) Show top CPU processes"
    echo "  b) Back"
    ask "Select: " || return
    case $REPLY_VAL in
      1) terminate_flow; pause ;;
      2) quit_app_flow; pause ;;
      3) view_top_memory; pause ;;
      4) view_top_cpu; pause ;;
      b|B|q|Q|"") return ;;
      *) echo "Unknown choice." ;;
    esac
  done
}

# =============================================================================
# Safe cleanup menu
# =============================================================================
cleanup_baseline() {
  CB_FREE=${FREE_PCT:-}; CB_LEVEL=${PRESS_LEVEL:-}; CB_SWAP=$SWAP_USED_MB; CB_USED=$MEM_USED_MB
  CB_GROUPS=$(group_totals); CLEAN_BASE_SET=1
}

suggest_closable() {
  section "APPLICATIONS YOU COULD CLOSE (measured: large memory, little recent CPU)"
  group_totals | awk -F'\t' -v min=$((APP_CANDIDATE_MIN_MB * 1024)) '
    ($2 == "App" || $2 == "Brave" || $2 == "ChatGPT" || $2 == "Cursor" || $2 == "Docker" || $2 == "VM" || $2 == "Local AI") && $4 >= min && $6 < 5 {
      printf "  - %-24s ~%6.0f MB, %4.1f%% CPU recently: if you are not using it, quitting frees most of this.\n", substr($1, 1, 24), $4 / 1024, $6; f = 1 }
    END { if (!f) print "  No idle application above the threshold." }'
  memory_sum_note
}

recheck_after_cleanup() {
  [ "$CLEAN_BASE_SET" = 1 ] || { echo "No baseline yet (it is taken when you open this menu)."; return; }
  info "Re-measuring..."
  snapshot_once fast
  section "BEFORE -> NOW"
  printf '  Memory pressure level: %s -> %s\n' "${CB_LEVEL:-?}" "${PRESS_LEVEL:-?}"
  printf '  macOS free estimate:   %s%% -> %s%%\n' "${CB_FREE:-?}" "${FREE_PCT:-?}"
  printf '  Memory used:           %s -> %s\n' "$(fmt_mb "$CB_USED")" "$(fmt_mb "$MEM_USED_MB")"
  printf '  Swap used:             %s -> %s\n' "$(fmt_mb "$CB_SWAP")" "$(fmt_mb "$SWAP_USED_MB")"
  { printf '%s\n' "$CB_GROUPS"; echo '#NOW'; group_totals; } | awk -F'\t' '
    $0 == "#NOW" { now = 1; next }
    !now && NF >= 6 { old[$1] = $4; next }
    now && NF >= 6 { new[$1] = $4 }
    END { for (k in old) { d = (k in new ? new[k] : 0) - old[k]; if (d < -51200 || d > 51200) printf "  %-26s %+7.0f MB%s\n", substr(k, 1, 26), d / 1024, (k in new ? "" : " (closed)") } }'
  note "  Swap is released gradually as data is read back or freed, so it may not drop right away."
}

cleanup_menu() {
  info "Taking a baseline measurement..."
  snapshot_once fast; cleanup_baseline
  while :; do
    section "SAFE CLEANUP"
    echo "  No script can add physical RAM. The only real fix for memory pressure is less work"
    echo "  at once: fewer windows, tabs, servers and models. Nothing runs without your confirmation;"
    echo "  this tool never purges caches, changes system settings, or uses sudo."
    echo "  1) Recheck memory and swap"
    echo "  2) Applications consuming the most resources"
    echo "  3) Development servers and runtimes"
    echo "  4) Docker containers and their resource usage"
    echo "  5) Cursor diagnostics (and how to open Cursor's own Process Explorer)"
    echo "  6) Suggest applications that could be closed"
    echo "  7) Terminate a specific process (with review + confirmation)"
    echo "  8) Quit an application gracefully"
    echo "  9) Recheck the system after cleanup (compare with baseline)"
    echo "  b) Back"
    ask "Select: " || return
    case $REPLY_VAL in
      1) view_memory; pause ;;
      2) view_top_memory; pause ;;
      3) view_dev; pause ;;
      4) section "DOCKER"; view_docker; pause ;;
      5) view_cursor; pause ;;
      6) snapshot_once precise; suggest_closable; pause ;;
      7) terminate_flow; pause ;;
      8) quit_app_flow; pause ;;
      9) recheck_after_cleanup; pause ;;
      b|B|q|Q|"") return ;;
      *) echo "Unknown choice." ;;
    esac
  done
}

# =============================================================================
# Free up memory: a ranked plan of what would free the most. Each step goes through the
# same review and confirmation as menu 10; nothing is batched and nothing runs unasked.
# =============================================================================
plan_measure() {   # fresh footprints; inside a work session, without touching its streaks
  if [ "$WORK_ACTIVE" = 1 ]; then
    collect_memory; collect_pressure; collect_swap
    S_PRECISE_TS=0; session_fresh_precise
  else
    info "Measuring per-process memory (about 2 s)..."
    snapshot_once precise
  fi
}

# kind \t mem_kb \t pid \t name \t bundle \t cpu   (largest first, at most 10)
#   proc: a development process (stopped via terminate_flow)
#   app:  a regular application (asked to quit via quit_app_do)
#   tabs: a browser (read-only advice: the manager cannot see or close tabs)
plan_items() {
  local self pid app bundle kb kind cpu
  self=" $(self_ancestors) "
  {
    dev_rows | awk -F'\t' '{ printf "proc\t%s\t%s\t%s\t-\t%s\n", $2, $1, $4, $3 }'
    list_gui_apps | while IFS="$TAB" read -r pid app bundle kb; do
      [ -n "$pid" ] || continue
      case $self in *" $pid "*) continue ;; esac   # the terminal running this manager
      [ "$kb" -ge $((APP_CANDIDATE_MIN_MB * 1024)) ] || continue
      case $app in Brave|Chrome|Arc|Firefox|Safari|"Microsoft Edge"|Vivaldi|Opera) kind=tabs ;; *) kind=app ;; esac
      cpu=$(group_totals | awk -F'\t' -v a="$app" '$1 == a { print $6; exit }')
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$kb" "$pid" "$app" "$bundle" "${cpu:-0}"
    done
  } | sort -t "$TAB" -k2,2nr | head -n 10
}

plan_app_effect() {   # app cpu -> what quitting it costs
  local idle=""
  awk -v c="$2" 'BEGIN { exit !(c + 0 < 5) }' && idle=" Idle right now (${2}% CPU)."
  case $1 in
    Cursor) echo "Stops its AI agents and terminals; it asks about unsaved files.$idle" ;;
    Docker) echo "Running containers stop.$idle" ;;
    *) echo "Closes its windows; it can ask you to save first. Reopen it when you need it.$idle" ;;
  esac
}

plan_record() {   # proc|app name pid -> session notes (work mode); 0 if something was done
  case $1 in
    proc)
      case $T_ACTION in
        sigterm|sigkill) [ "$WORK_ACTIVE" = 1 ] && { session_note USER "approved (free-up plan): stopped $2 (PID $3, $T_ACTION)"; session_watch_effect "stop $2"; }; return 0 ;;
        left) [ "$WORK_ACTIVE" = 1 ] && session_note USER "approved SIGTERM for $2 (PID $3); it kept running and you declined SIGKILL" ;;
        cancelled) [ "$WORK_ACTIVE" = 1 ] && session_note USER "declined (free-up plan): stopping $2 (PID $3)" ;;
        refused) [ "$WORK_ACTIVE" = 1 ] && session_note USER "refused by safety checks: $2 (PID $3)" ;;
      esac ;;
    app)
      case $QA_ACTION in
        asked) [ "$WORK_ACTIVE" = 1 ] && { session_note USER "approved (free-up plan): asked $QA_NAME to quit"; session_watch_effect "quit $QA_NAME"; }; return 0 ;;
        cancelled) [ "$WORK_ACTIVE" = 1 ] && session_note USER "declined (free-up plan): quitting $QA_NAME" ;;
      esac ;;
  esac
  return 1
}

free_memory_plan() {
  local items n line kind kb pid name bundle cpu ports port i what eff f0 u0 s0 fb ub done_list=""
  plan_measure
  f0=${FREE_PCT:-?}; u0=$MEM_USED_MB; s0=$SWAP_USED_MB
  while :; do
    items=$(plan_items)
    section "FREE UP MEMORY - ranked plan"
    printf '  Now: pressure %s, macOS free estimate %s%%, memory used %s, swap %s\n' \
      "$(pressure_text)" "${FREE_PCT:-?}" "$(fmt_mb "$MEM_USED_MB")" "$(fmt_mb "$SWAP_USED_MB")"
    if [ -z "$items" ]; then
      echo "  Nothing large enough to suggest (development processes >= ${DEV_CANDIDATE_MIN_MB} MB, apps >= ${APP_CANDIDATE_MIN_MB} MB)."
      break
    fi
    ports=$(list_listeners 2>/dev/null); i=0
    while IFS="$TAB" read -r kind kb pid name bundle cpu; do
      [ -n "$kind" ] || continue
      i=$((i + 1))
      case $kind in
        proc) port=$(printf '%s\n' "$ports" | awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }')
              what="stop process (PID $pid)"; eff="If stopped: $(dev_impact "$name" "$port")" ;;
        app)  what="quit app"; eff=$(plan_app_effect "$name" "$cpu") ;;
        tabs) what="close heavy tabs"; eff="Shows how to find the heaviest tabs (read-only: the manager cannot see or close tabs)." ;;
      esac
      printf '  %2d) %-30s ~%-8s %s\n' "$i" "$(printf '%s' "$name" | cut -c1-30)" "$(fmt_mb $((kb / 1024)))" "$what"
      printf '      %s\n' "$eff"
    done <<EOF
$items
EOF
    echo "  Sizes are physical footprints and overlap (a process started by an app is also in that app's total)."
    echo "  Nothing happens until you pick a number, and each step shows its own review and asks again."
    ask "Number to act on (Enter = done): " || break
    n=$(trim "$REPLY_VAL")
    [ -n "$n" ] || break
    is_uint "$n" || { echo "Not a number. Nothing was done."; continue; }
    line=$(printf '%s\n' "$items" | awk -v n="$n" 'NR == n')
    [ -n "$line" ] || { echo "No such entry. Nothing was done."; continue; }
    IFS="$TAB" read -r kind kb pid name bundle cpu <<EOF
$line
EOF
    fb=${FREE_PCT:-?}; ub=$MEM_USED_MB
    case $kind in
      tabs) session_browser; continue ;;
      proc) terminate_flow "$pid" ;;
      app) quit_app_do "$pid" "$name" "$bundle" ;;
    esac
    plan_record "$kind" "$name" "$pid" || continue
    done_list="$done_list${done_list:+, }$name"
    sleep 2
    plan_measure
    printf '  Effect so far: macOS free estimate %s%% -> %s%%, memory used %s -> %s (macOS may need a minute to settle).\n' \
      "$fb" "${FREE_PCT:-?}" "$(fmt_mb "$ub")" "$(fmt_mb "$MEM_USED_MB")"
  done
  if [ -n "$done_list" ]; then
    section "FREE-UP SUMMARY"
    printf '  Done: %s\n' "$done_list"
    printf '  Since the plan started: macOS free estimate %s%% -> %s%%, memory used %s -> %s, swap %s -> %s\n' \
      "$f0" "${FREE_PCT:-?}" "$(fmt_mb "$u0")" "$(fmt_mb "$MEM_USED_MB")" "$(fmt_mb "$s0")" "$(fmt_mb "$SWAP_USED_MB")"
    note "  Swap shrinks only gradually, as macOS reads data back or frees it."
    log_event ACTION "free-up plan: $done_list"
  else
    echo "Nothing was changed."
  fi
}

# =============================================================================
# Modes
# =============================================================================
restore_terminal() {
  if [ "$LIVE_ACTIVE" = 1 ]; then
    printf '\033[?25h\033[?1049l'
    LIVE_ACTIVE=0
  fi
  if [ -n "$SAVED_STTY" ]; then stty "$SAVED_STTY" 2>/dev/null; SAVED_STTY=""; fi
}

wait_or_key() {   # seconds -> returns 1 if user pressed q
  local key=""
  if is_tty; then
    IFS= read -r -s -n 1 -t "$1" key
    case $key in q|Q) return 1 ;; esac
  else
    sleep "$1" & SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
  fi
  [ "$STOP_REQUESTED" = 1 ] && return 1
  return 0
}

live_mode() {
  init_monitor_state; seed_swap_history "$(now_epoch)"; collect_uptime; load_model_name
  DISK_INTERVAL=60
  if ! is_tty; then
    monitor_tick precise; render_overview; return 0
  fi
  SAVED_STTY=$(stty -g 2>/dev/null)
  stty -echo 2>/dev/null
  printf '\033[?1049h\033[?25l'; LIVE_ACTIVE=1
  local out
  while :; do
    monitor_tick fast
    process_events; EVENT_LINES=""
    [ $((TICKS % 15)) -eq 0 ] && collect_uptime
    out=$(render_overview)
    printf '\033[H\033[2J%s\n\n%sRefresh every %ss | q = back | Ctrl+C = exit%s' "$out" "$C_DIM" "$LIVE_INTERVAL_SEC" "$C_RST"
    wait_or_key "$LIVE_INTERVAL_SEC" || break
  done
  restore_terminal
}

# pid -> start time in UTC (unaffected by a time-zone or DST change while it runs), spaces normalised
proc_start() { TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null | awk '{ $1 = $1; print }'; }

pidfile_alive() {   # -> prints pid if a live work-mode instance owns the pidfile
  [ "$DIRS_OK" = 1 ] && [ -f "$PIDFILE" ] || return 1
  local pid st args; pid=$(head -n 1 "$PIDFILE" 2>/dev/null | tr -cd '0-9'); st=$(sed -n 2p "$PIDFILE" 2>/dev/null | awk '{ $1 = $1; print }')
  is_uint "$pid" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # The owner records its own PID and start time. That pair identifies it however work mode was
  # started (--work, menu item 11, a symlink such as ~/bin/mpm), and a reused PID has a later
  # start time, so it is never mistaken for the owner.
  [ -n "$st" ] && [ "$(proc_start "$pid")" = "$st" ] && { echo "$pid"; return 0; }
  # Pidfile written by an older version (local-time or no start time): its own --work command line.
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  case $args in *mac-performance-manager*--work*) echo "$pid"; return 0 ;; esac
  return 1
}

# mkdir is atomic: only one instance at a time can run "check the pidfile, then claim it", so two
# work modes started at the same moment cannot both start. Held for milliseconds only.
work_lock() {   # acquire|release
  local lock="$STATE_DIR/work.lock" i=0
  if [ "$1" = release ]; then
    [ "$WORK_LOCK_HELD" = 1 ] && rmdir "$lock" 2>/dev/null
    WORK_LOCK_HELD=0; return 0
  fi
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 30 ] && return 1
    # A lock older than a minute was left by an instance killed while holding it.
    if [ -n "$(find "$lock" -maxdepth 0 -type d -mmin +1 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null; continue; fi
    sleep 0.1
  done
  WORK_LOCK_HELD=1
}

remove_own_pidfile() {
  if [ "$OWN_PIDFILE" = 1 ] && [ -f "$PIDFILE" ]; then
    [ "$(head -n 1 "$PIDFILE" 2>/dev/null | tr -cd '0-9')" = "$$" ] && rm -f -- "$PIDFILE"
    OWN_PIDFILE=0
  fi
}

# =============================================================================
# Work session supervisor (runs in the foreground; nothing is left running after it)
# =============================================================================
# Automatic actions change only the manager's OWN behaviour: sampling interval,
# reuse of the latest sample, deferring expensive scans under pressure, and stopping
# its own helper processes. They cannot free memory used by other apps. That needs an
# action you approve (keys d / k), which always goes through terminate_flow or
# quit_app_flow with their review, typed confirmation and identity checks.

session_init() {
  S_START=$(now_epoch); S_SAMPLES=0; S_N_OK=0; S_N_WATCH=0; S_N_HIGH=0; S_N_CRIT=0; S_N_UNK=0
  S_MIN_FREE=""; S_PEAK="OK"; S_PEAK_SWAP=0; S_START_SWAP=""; S_PEAK_SWAPOUT=0; S_SWAPOUTS0=""; S_SWAPINS0=""
  S_CACHE_HITS=0; S_AUTO=""; S_USER=""; S_USER_N=0; S_AFTER=""; S_PENDING=""; S_WORST_GROUPS=""
  S_START_LINE=""; S_PROBLEM_GROUPS=""; S_PROBLEM_TS=0; S_PROBLEM_USER_N=0; S_MODE=NORMAL
  S_INTERVAL=$WORK_INTERVAL_SEC; S_STABLE=0; S_RELAXED_SEC=0; S_LAST_TS=0; S_LAST_HINT_TS=0
  S_CMD=""; S_FORCE=0; S_EOF_N=0; S_DISK_HINT=""; S_RECO_PRINTED=0; S_PRECISE_TS=0; S_PRECISE_N=0
  S_IDLE_BASE=""; S_AP_SKIP=" "; S_AP=""; S_AP_LAST=0; S_AP_N=0; S_AP_WATCH=""; S_AUTO_SEEN=""
  S_PAUSE_TS=0; S_PAUSE_DEV=0; S_INEFF_TS=0; S_INEFF_DEV=0
  S_HIGH_TOTAL=0; S_HIGH_SINCE=0; S_ACTION_LOG=""
  if [ -t 0 ]; then S_INPUT=tty; elif [ -p /dev/stdin ]; then S_INPUT=pipe; else S_INPUT=none; fi
}

session_say() { is_tty && printf '\r\033[K'; printf '%s\n' "$*"; }

# Per-process memory for diagnoses. Routine samples use ps RSS, which leaves out compressed
# memory and can undercount heavy apps several times over on a pressured Mac. A diagnosis
# therefore uses one `top` sample (physical footprint, ~1-2 s CPU). It runs only when you
# ask, or once when a pressure warning starts, and is reused until the next routine sample.
session_fresh_precise() {
  if [ "$S_PRECISE_TS" != 0 ] && [ "$PROC_MEM_SRC" = FOOTPRINT ]; then S_CACHE_HITS=$((S_CACHE_HITS + 1)); return 0; fi
  [ "$HAVE_TOP" = 1 ] || return 0
  is_tty && printf '\r\033[K'
  echo "Measuring per-process memory (about 2 s)..."
  collect_procs precise
  S_PRECISE_TS=$(now_epoch); S_PRECISE_N=$((S_PRECISE_N + 1))
  # The report's "largest groups at the worst moment" should use these footprints, not RSS.
  [ -n "$FREE_PCT" ] && [ "$FREE_PCT" = "$S_MIN_FREE" ] && S_WORST_GROUPS=$(group_totals | head -n 5)
  return 0
}

session_note() {   # AUTO|USER|AFTER text  (bounded, names and PIDs only; also logged)
  local line; line="[$(date '+%H:%M')] $2"
  case $1 in
    AUTO) S_AUTO=$(printf '%s\n%s\n' "$S_AUTO" "$line" | awk 'NF' | tail -n 40); log_event AUTO "$2" ;;
    USER) S_USER=$(printf '%s\n%s\n' "$S_USER" "$line" | awk 'NF' | tail -n 40); S_USER_N=$((S_USER_N + 1)); log_event ACTION "$2" ;;
    AFTER) S_AFTER=$(printf '%s\n%s\n' "$S_AFTER" "$line" | awk 'NF' | tail -n 40); log_event INFO "$2" ;;
  esac
  S_ACTION_LOG=$(printf '%s\n%s\t%s\n' "$S_ACTION_LOG" "$1" "$line" | awk 'NF' | tail -n 80)
}

# Sets S_CPU_MS: CPU time used so far by this shell and every helper it has waited for.
# `times` must run in this shell, not in $(...), hence the small temporary file.
session_measure_cpu() {
  S_CPU_MS=""
  [ "$DIRS_OK" = 1 ] || return 0
  local f="$STATE_DIR/.times.$$"
  times > "$f" 2>/dev/null || return 0
  S_CPU_MS=$(awk '{ for (i = 1; i <= NF; i++) { m = $i; sub(/m.*/, "", m); s = $i; sub(/^[0-9]+m/, "", s); sub(/s$/, "", s); t += m * 60 + s } }
    END { printf "%d", t * 1000 }' "$f")
  rm -f -- "$f"
}

# Development processes of this user: pid \t mem_kb \t cpu \t name \t started_by (largest first)
dev_rows() {
  printf '%s\n' "$PROCS" | awk -F'\t' -v me="$CURRENT_UID" -v min=$((DEV_CANDIDATE_MIN_MB * 1024)) '
    NF >= 12 && $3 == me && $6 >= min {
      l = tolower($10)
      if ($9 == "Node.js" || $9 == "Python" || $9 == "JS runtime" ||
          l ~ /^(next-server|next-router-worker|tsserver|typingsinstaller|vite|webpack|esbuild|turbo|nodemon|ts-node|tsx|eslint|prettier|tailwindcss|npm|pnpm|yarn|uvicorn|gunicorn|jest|vitest)/)
        printf "%s\t%s\t%s\t%s\t%s\n", $1, $6, $5, $10, $11 }' | sort -t "$TAB" -k2,2nr
}

dev_summary() {   # one line: "next-server x1, tsserver x3 (~6.8 GB, approximate)"
  dev_rows | awk -F'\t' '{ k = $4; sub(/[ \[(].*/, "", k); n[k]++; m += $2; t++ }
    END { if (!t) exit; for (k in n) s = s (s ? ", " : "") k " x" n[k]; printf "%s (~%.1f GB, approximate)\n", s, m / 1048576 }'
}

dev_impact() {   # name port -> what breaks if it stops
  local low; low=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case $low in
    tsserver*|typingsinstaller*) echo "TypeScript errors/autocomplete pause in one Cursor window; Cursor usually restarts it. Gentler: Cmd+Shift+P 'TypeScript: Restart TS Server' or close that window." ;;
    eslint*|prettier*) echo "Lint/format in the editor pauses until the editor restarts it." ;;
    *) if [ -n "$2" ]; then echo "The server on port $2 stops; open pages and API calls fail until you restart it (e.g. npm run dev)."
       else echo "Whatever it runs stops (server, watcher, build, agent or MCP tool). Check the command line in the review."; fi ;;
  esac
}

session_watch_effect() {   # label: compare two samples later (correlation, not proof)
  S_PENDING="2|$1|${FREE_PCT:-?}|$MEM_USED_MB|${SWAPOUT_RATE:-?}|$VERDICT"
}

session_check_pending() {
  [ -n "$S_PENDING" ] || return 0
  local n=${S_PENDING%%|*} rest=${S_PENDING#*|} label free used so v
  n=$((n - 1))
  if [ "$n" -gt 0 ]; then S_PENDING="$n|$rest"; return 0; fi
  IFS='|' read -r label free used so v <<EOF
$rest
EOF
  session_note AFTER "after '$label': status $v -> $VERDICT, macOS free estimate $free% -> ${FREE_PCT:-?}%, memory used $(fmt_mb "$used") -> $(fmt_mb "$MEM_USED_MB"), swap-out $so -> ${SWAPOUT_RATE:-?} pages/s (2 samples later)"
  session_say "Measured after '$label': free estimate $free% -> ${FREE_PCT:-?}%, swap-out $so -> ${SWAPOUT_RATE:-?} pages/s (correlation, not proof)."
  S_PENDING=""
}

session_record_sample() {   # now
  S_SAMPLES=$((S_SAMPLES + 1)); S_LAST_TS=$1; S_PRECISE_TS=0
  case $VERDICT in
    OK) S_N_OK=$((S_N_OK + 1)) ;; WATCH) S_N_WATCH=$((S_N_WATCH + 1)) ;; HIGH) S_N_HIGH=$((S_N_HIGH + 1)) ;;
    CRITICAL) S_N_CRIT=$((S_N_CRIT + 1)) ;; *) S_N_UNK=$((S_N_UNK + 1)) ;;
  esac
  case $VERDICT in CRITICAL) S_PEAK=CRITICAL ;; HIGH) [ "$S_PEAK" != CRITICAL ] && S_PEAK=HIGH ;; WATCH) [ "$S_PEAK" = OK ] && S_PEAK=WATCH ;; esac
  if [ -z "$S_SWAPOUTS0" ] && [ "$MEM_OK" = 1 ]; then
    S_SWAPOUTS0=$VM_SWAPOUTS; S_SWAPINS0=$VM_SWAPINS; S_START_SWAP=$SWAP_USED_MB; S_START_LINE=$(work_status_line)
  fi
  [ "$SWAP_USED_MB" -gt "$S_PEAK_SWAP" ] && S_PEAK_SWAP=$SWAP_USED_MB
  if is_uint "${SWAPOUT_RATE:-}" && [ "$SWAPOUT_RATE" -gt "$S_PEAK_SWAPOUT" ]; then S_PEAK_SWAPOUT=$SWAPOUT_RATE; fi
  if [ -n "$FREE_PCT" ] && { [ -z "$S_MIN_FREE" ] || [ "$FREE_PCT" -lt "$S_MIN_FREE" ]; }; then
    S_MIN_FREE=$FREE_PCT; S_WORST_GROUPS=$(group_totals | head -n 5)
  fi
  [ "$S_INTERVAL" -gt "$WORK_INTERVAL_SEC" ] && S_RELAXED_SEC=$((S_RELAXED_SEC + S_INTERVAL))
  session_track_idle "$1"
  session_check_pending
  session_check_auto_effect
}

session_pressure_brief() {
  session_fresh_precise
  session_say ""
  session_say "HIGH MEMORY PRESSURE - $VERDICT_REASON"
  if [ "$S_RECO_PRINTED" = 0 ]; then
    echo "Likely contributors now (approximate: shared memory is counted more than once):"
    group_totals | awk -F'\t' '$2 != "System" { printf "  - %s ~%.1f GB (%d processes)\n", $1, $4 / 1048576, $3; if (++n == 4) exit }'
  fi
  local d; d=$(dev_summary); [ -n "$d" ] && echo "Development processes: $d"
  echo "Options (monitoring continues): f = free up memory (ranked plan, you approve each step), d = diagnose,"
  echo "  k = stop a dev process, t = top consumers."
  if auto_rules_on; then
    printf 'Ignoring this is fine. Only your opt-in rule(s) may act: %s, after a %ss notice (x cancels). Apps are never quit.\n' \
      "$( { [ "$AUTO_STOP_IDLE_TSSERVER" = true ] && echo "idle TypeScript servers"; [ "$AUTO_STOP_IDLE_DEVSERVER" = true ] && echo "idle dev servers"; } | paste -sd, - | sed 's/,/ and /')" \
      "$AUTO_ACTION_GRACE_SEC"
  else
    echo "Ignoring this is fine: nothing is closed automatically."
  fi
}

session_recovery() {   # now
  local dur=$(($1 - S_PROBLEM_TS)) changes acts=""
  changes=$( { printf '%s\n' "$S_PROBLEM_GROUPS"; echo '#NOW'; group_totals; } | awk -F'\t' '
    $0 == "#NOW" { now = 1; next }
    !now && NF >= 6 { old[$1] = $4; next }
    now && NF >= 6 { new[$1] = $4 }
    END { for (k in old) { d = (k in new ? new[k] : 0) - old[k]; if (d <= -102400) printf "%d\t  %s %+.1f GB%s\n", d, k, d / 1048576, (k in new ? "" : " (no longer running)") } }' |
    sort -t "$TAB" -k1,1n | head -n 5 | cut -f2-)
  [ "$S_USER_N" -gt "$S_PROBLEM_USER_N" ] && acts=$(printf '%s\n' "$S_USER" | tail -n $((S_USER_N - S_PROBLEM_USER_N)))
  session_say ""
  session_say "RECOVERY - memory status is $VERDICT again after $(fmt_duration "$dur") of high pressure."
  if [ -n "$changes" ]; then echo "Biggest drops since it started (correlation, not proof):"; printf '%s\n' "$changes"; fi
  if [ -n "$acts" ]; then echo "Your actions in that period:"; printf '%s\n' "$acts" | sed 's/^/  /'; fi
  session_note AFTER "recovered from high pressure after $(fmt_duration "$dur")$( [ -n "$changes" ] && printf '; biggest drop:%s' "$(printf '%s\n' "$changes" | head -n 1)")"
}

session_update_mode() {   # now
  local now=$1 old=$S_MODE new target reason
  case $VERDICT in HIGH|CRITICAL) new=HIGH ;; WATCH) new=ELEVATED ;; OK) new=NORMAL ;; *) new=$old ;; esac
  if [ "$old" = HIGH ] && [ "$new" != HIGH ] && [ "$S_HIGH_SINCE" != 0 ]; then
    S_HIGH_TOTAL=$((S_HIGH_TOTAL + now - S_HIGH_SINCE)); S_HIGH_SINCE=0
  fi
  [ "$old" = HIGH ] && [ "$new" != HIGH ] && session_recovery "$now"
  if [ "$new" = HIGH ] && [ "$old" != HIGH ]; then
    S_HIGH_SINCE=$now
    S_PROBLEM_TS=$now; S_PROBLEM_USER_N=$S_USER_N; S_PROBLEM_GROUPS=$(group_totals)
    session_pressure_brief; S_LAST_HINT_TS=$now
  elif [ "$new" = HIGH ] && [ $((now - S_LAST_HINT_TS)) -ge $((NOTIFY_COOLDOWN_MIN * 60)) ]; then
    session_pressure_brief; S_LAST_HINT_TS=$now
  elif [ "$new" = ELEVATED ] && [ "$old" = NORMAL ]; then
    if [ "$S_LAST_HINT_TS" = 0 ] || [ $((now - S_LAST_HINT_TS)) -ge $((NOTIFY_COOLDOWN_MIN * 60)) ]; then
      S_LAST_HINT_TS=$now
      session_fresh_precise
      session_say "Memory is getting tight ($VERDICT_REASON). Largest now: $(group_totals | awk -F'\t' '$2 != "System" { printf "%s%s ~%.1f GB", (n++ ? ", " : ""), $1, $4 / 1048576; if (n == 3) exit }')."
      echo "No action needed yet; warnings need ${SUSTAINED_SAMPLES} samples in a row. Press d to diagnose."
    fi
  fi
  case $DISK_STATE in
    LOW|CRITICAL) if [ "$S_DISK_HINT" != "$DISK_STATE" ]; then S_DISK_HINT=$DISK_STATE
        session_say "Disk free space is $DISK_STATE ($(fmt_mb "$DISK_AVAIL_MB")). Press c to review cleanup candidates; nothing is deleted automatically."; fi ;;
    *) S_DISK_HINT="" ;;
  esac
  # Adaptive sampling (the manager's own cost only): relax while stable, back to normal otherwise.
  if [ "$new" = NORMAL ]; then S_STABLE=$((S_STABLE + 1)); else S_STABLE=0; fi
  target=$WORK_INTERVAL_SEC; reason="memory status $VERDICT"
  if [ "$WORK_RELAX_AFTER_SAMPLES" -gt 0 ] && [ "$S_STABLE" -ge "$WORK_RELAX_AFTER_SAMPLES" ]; then
    target=$WORK_RELAXED_INTERVAL_SEC; reason="stable for $S_STABLE samples"
  fi
  if [ "$target" != "$S_INTERVAL" ]; then
    session_note AUTO "sampling interval ${S_INTERVAL}s -> ${target}s ($reason)"
    session_say "Auto: sampling interval ${S_INTERVAL}s -> ${target}s ($reason)."
    S_INTERVAL=$target
  fi
  S_MODE=$new
  session_auto_schedule "$now"
}

# Wait up to N seconds in 1-second slices (bash 3.2's read -t is not interrupted by a
# trapped Ctrl+C, so long reads would delay stopping). Sets S_CMD if a command arrives.
session_wait() {   # seconds -> 1 if the session should stop
  local left=$1 line rc t0 el
  S_CMD=""
  while [ "$left" -gt 0 ] && [ "$STOP_REQUESTED" = 0 ]; do
    case $S_INPUT in
      tty|pipe)
        line=""; t0=$SECONDS
        if [ "$S_INPUT" = tty ]; then IFS= read -r -s -n 1 -t 1 line; rc=$?; else IFS= read -r -t 1 line; rc=$?; fi
        el=$((SECONDS - t0))
        if [ -n "$line" ]; then S_CMD=$line; S_EOF_N=0; return 0; fi
        if [ "$rc" != 0 ] && [ "$el" = 0 ]; then   # end of input, not a timeout
          S_EOF_N=$((S_EOF_N + 1)); [ "$S_EOF_N" -ge 3 ] && S_INPUT=none
        else
          S_EOF_N=0
        fi
        left=$((left - el)) ;;
      *)
        sleep "$left" & SLEEP_PID=$!
        wait "$SLEEP_PID" 2>/dev/null
        SLEEP_PID=""; left=0 ;;
    esac
  done
  [ "$STOP_REQUESTED" = 1 ] && return 1
  return 0
}

# --- Automatic rules (each opt-in) --------------------------------------------------------
#   AUTO_STOP_IDLE_TSSERVER    TypeScript language servers started by an editor extension host
#   AUTO_STOP_IDLE_DEVSERVER   local Next.js / Vite dev servers (the `next dev` / `vite` launcher)
# Shared conditions: sustained HIGH/CRITICAL pressure; idle (average CPU <= 0.5% of one core,
# + 1 s slack) for the rule's whole idle period as observed by this session; positive
# identification; no busy child, build/test or AI agent involved; announced
# AUTO_ACTION_GRACE_SEC ahead (x cancels); everything re-verified right before SIGTERM
# (protections, identity/PID reuse, idleness, pressure). Never SIGKILL, never a restart.
# Least disruptive first (TypeScript servers restart on demand). AUTO_COOLDOWN_MIN between
# actions, AUTO_MAX_ACTIONS per session, and a rule pauses itself after AUTO_MAX_INEFFECTIVE
# actions that did not measurably help.

AGENT_NAMES_RE='^(claude|codex|aider|cursor-agent|gemini|opencode|goose|amp|copilot)$'
BUSY_NAMES_RE='^(tsc|webpack|esbuild|rollup|turbo|jest|vitest|playwright|cypress|mocha|eslint|prettier|npx|git|make|cargo|pytest|xcodebuild|swift-build|docker)$'
DEV_LAUNCHER_RE='node_modules/(\.bin/next|next/dist/bin/next) dev( |$)|node_modules/(\.bin/vite|vite/bin/vite\.js)( dev| serve)?( |$)'
# Command lines of builds, tests, type checks and linters (they usually run as "node").
WORK_ARGS_RE='(^|[ /])(tsc|jest|vitest|playwright|cypress|mocha|webpack|rollup|esbuild|turbo|nx|tsup|biome|eslint|prettier|tsx)( |$)|(^|[ /])(next|vite|nuxt|astro|remix) (build|lint|test)( |$)|(^|[ /])(npm|pnpm|yarn|bun)( run)? (build|test|lint|typecheck|check|e2e)( |$)'
# Command lines of AI coding agents (some run as "node .../cli.js").
AGENT_ARGS_RE='claude-code|(^|[ /])(claude|codex|aider|cursor-agent|gemini|opencode|goose|amp)( |$)'

auto_rules_on() { [ "$AUTO_STOP_IDLE_TSSERVER" = true ] || [ "$AUTO_STOP_IDLE_DEVSERVER" = true ]; }

# Units to watch: key \t kind \t target \t pids(comma) (target plus its direct children).
session_idle_units() {
  local me=$CURRENT_UID nodes args
  if [ "$AUTO_STOP_IDLE_TSSERVER" = true ]; then
    printf '%s\n' "$PROCS" | awk -F'\t' -v me="$me" 'NF >= 12 && $3 == me && tolower($10) ~ /^tsserver/ { printf "ts:%s\tts\t%s\t%s\n", $1, $1, $1 }'
  fi
  [ "$AUTO_STOP_IDLE_DEVSERVER" = true ] || return 0
  nodes=$(printf '%s\n' "$PROCS" | awk -F'\t' -v me="$me" 'NF >= 12 && $3 == me && tolower($10) ~ /^(node|next|vite)/ { printf "%s%s", s, $1; s = "," }')
  [ -n "$nodes" ] || return 0
  args=$(ps -ww -o pid=,args= -p "$nodes" 2>/dev/null | awk -v re="$DEV_LAUNCHER_RE" '$0 ~ re && $0 !~ / (build|preview)( |$)/ { print $1 }')
  [ -n "$args" ] || return 0
  { printf '%s\n' "$args"; echo '#P'; printf '%s\n' "$PROCS"; } | awk -F'\t' '
    $0 == "#P" { p = 1; next }
    !p { t[$1] = 1; next }
    p && NF >= 12 { par[$1] = $2; ids[++n] = $1 }
    END { for (i = 1; i <= n; i++) { x = ids[i]; if (x in t) tree[x] = tree[x] "," x
            q = par[x]; d = 0; while (q != "" && d < 64) { if (q in t) { tree[q] = tree[q] "," x; break } q = par[q]; d++ } }
          for (x in t) if (x in tree) printf "dev:%s\tdev\t%s\t%s\n", x, x, substr(tree[x], 2) }'
}

# S_IDLE_BASE: key \t cpu_s \t idle_since \t kind \t target \t pids
session_track_idle() {   # now
  auto_rules_on || return 0
  local units allp cur
  units=$(session_idle_units)
  if [ -z "$units" ]; then S_IDLE_BASE=""; return 0; fi
  allp=$(printf '%s\n' "$units" | awk -F'\t' '{ printf "%s%s", s, $4; s = "," }')
  cur=$(ps -o pid=,time= -p "$allp" 2>/dev/null | awk 'NF == 2 { n = split($2, a, ":"); t = 0; for (i = 1; i <= n; i++) t = t * 60 + a[i]; printf "%s\t%.2f\n", $1, t }')
  S_IDLE_BASE=$( { printf '%s\n' "$S_IDLE_BASE"; echo '#CUR'; printf '%s\n' "$cur"; echo '#U'; printf '%s\n' "$units"; } | awk -F'\t' -v now="$1" '
    $0 == "#CUR" { sec = 1; next }
    $0 == "#U" { sec = 2; next }
    sec == 0 && NF >= 3 { bc[$1] = $2; bt[$1] = $3; next }
    sec == 1 && NF == 2 { c[$1] = $2; next }
    sec == 2 && NF >= 4 {
      n = split($4, p, ","); s = 0; seen = 0
      for (i = 1; i <= n; i++) if (p[i] in c) { s += c[p[i]]; if (p[i] == $3) seen = 1 }
      if (!seen) next
      if (($1 in bc) && s - bc[$1] >= 0 && s - bc[$1] <= 1 + 0.005 * (now - bt[$1])) printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, bc[$1], bt[$1], $2, $3, $4
      else printf "%s\t%.2f\t%s\t%s\t%s\t%s\n", $1, s, now, $2, $3, $4 }')
}

proc_descendants() {   # pid -> pid \t name \t cpu of every descendant (from the latest sample)
  printf '%s\n' "$PROCS" | awk -F'\t' -v root="$1" 'NF >= 12 { par[$1] = $2; nm[$1] = $10; cp[$1] = $5; ids[++n] = $1 }
    END { for (i = 1; i <= n; i++) { q = par[ids[i]]; d = 0
            while (q != "" && d < 64) { if (q == root) { printf "%s\t%s\t%s\n", ids[i], nm[ids[i]], cp[ids[i]]; break } q = par[q]; d++ } } }'
}

proc_agent_ancestor() {   # pid -> name of an AI-agent ancestor (by process name or command line), if any
  local chain hit
  chain=$(printf '%s\n' "$PROCS" | awk -F'\t' -v p="$1" -v re="$AGENT_NAMES_RE" 'NF >= 12 { par[$1] = $2; nm[$1] = tolower($10) }
    END { q = par[p]; d = 0; while (q != "" && q + 0 > 1 && d < 64) { if (nm[q] ~ re) { print "NAME " nm[q]; exit } printf "%s%s", (d ? "," : ""), q; q = par[q]; d++ } }')
  case $chain in "NAME "*) echo "${chain#NAME }"; return ;; esac
  [ -n "$chain" ] || return 0
  hit=$(ps -ww -o args= -p "$chain" 2>/dev/null | tr 'A-Z' 'a-z' | awk -v re="$AGENT_ARGS_RE" 'match($0, re) { h = substr($0, RSTART, RLENGTH); gsub(/[ \/]/, "", h); print h; exit }')
  [ -n "$hit" ] && echo "$hit"
  return 0
}

path_related() {   # a b -> 0 if one folder is inside the other (same project or monorepo)
  case $1/ in "$2"/*) return 0 ;; esac
  case $2/ in "$1"/*) return 0 ;; esac
  return 1
}

# Builds/tests/agents of this user, by command line: pid \t kind \t first word (no cap).
user_work_procs() {   # exclude_pids(comma)
  local all
  all=$(printf '%s\n' "$PROCS" | awk -F'\t' -v me="$CURRENT_UID" 'NF >= 12 && $3 == me && $1 != "" { printf "%s%s", s, $1; s = "," }')
  [ -n "$all" ] || return 0
  ps -ww -o pid=,args= -p "$all" 2>/dev/null | awk -v ex=",$1," -v w="$WORK_ARGS_RE" -v a="$AGENT_ARGS_RE" '
    index(ex, "," $1 ",") == 0 { l = tolower($0); sub(/^ *[0-9]+ +/, "", l)
      if (l ~ /^tsserver|tsserver\.js|eslintserver|server\.js --node-ipc/) next
      if (l ~ a) printf "%s\tagent\t%s\n", $1, $2; else if (l ~ w) printf "%s\twork\t%s\n", $1, $2 }'
}

busy_reason() {   # pid -> why its subtree looks busy (empty = not busy)
  local d why kids
  d=$(proc_descendants "$1")
  [ -n "$d" ] || return 0
  why=$(printf '%s\n' "$d" | awk -F'\t' -v re="$BUSY_NAMES_RE" '{ n = tolower($2); sub(/[ \[(].*/, "", n)
    if (n ~ re) { printf "a %s process is running under it\n", n; exit }
    if ($3 + 0 >= 5) { printf "a child process is busy (%s, %.0f%% CPU)\n", $2, $3; exit } }')
  [ -n "$why" ] && { echo "$why"; return; }
  kids=$(printf '%s\n' "$d" | awk -F'\t' '{ printf "%s%s", s, $1; s = "," }')
  ps -ww -o args= -p "$kids" 2>/dev/null | tr 'A-Z' 'a-z' | awk -v re="$WORK_ARGS_RE" '$0 ~ re { printf "a build/test is running under it (%s)\n", $1; exit }'
}

# Files of the project changed within N minutes (generated folders ignored). Prints "yes",
# "no", or "unknown" when the check could not finish (then nothing is stopped).
project_recent_edits() {   # folder minutes
  local out rc
  out=$(run_with_timeout 10 find "$1" -maxdepth 6 \( -name node_modules -o -name .git -o -name .next -o -name .turbo -o -name .cache \
    -o -name dist -o -name build -o -name coverage -o -name .svelte-kit -o -name .vite \) -prune -o -type f -mmin -"$2" -print -quit 2>/dev/null)
  rc=$?
  if [ -n "$out" ]; then echo yes; elif [ "$rc" = 0 ]; then echo no; else echo unknown; fi
}

ts_verify() {   # pid -> OK, or the reason it is not eligible
  local row parent why
  row=$(printf '%s\n' "$PROCS" | awk -F'\t' -v p="$1" '$1 == p { print $2 "\t" $10; exit }')
  case $(printf '%s' "${row#*"$TAB"}" | tr 'A-Z' 'a-z') in tsserver*) ;; *) echo "not identified as a TypeScript server"; return ;; esac
  parent=$(printf '%s\n' "$PROCS" | awk -F'\t' -v p="${row%%"$TAB"*}" '$1 == p { print $10; exit }')
  case $parent in *"Helper (Plugin)"*) ;; *) echo "its parent is not an editor extension host"; return ;; esac
  why=$(busy_reason "$1"); [ -n "$why" ] && { echo "$why"; return; }
  echo OK
}

dev_verify() {   # target pids -> "OK \t port \t project", or the reason it is not eligible
  local t=$1 pids=$2 args listen est cwd agent why
  [ "$HAVE_LSOF" = 1 ] || { echo "listening ports cannot be checked (lsof unavailable)"; return; }
  args=$(ps -ww -o args= -p "$t" 2>/dev/null)
  printf '%s\n' "$args" | awk -v re="$DEV_LAUNCHER_RE" '$0 ~ re { f = 1 } END { exit !f }' || { echo "not identified as a Next.js/Vite dev server"; return; }
  check_terminable "$t" || { echo "$T_REASON"; return; }
  listen=$(run_with_timeout 10 lsof -nP -a -p "$pids" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | awk '/^n/ { s = substr($0, 2); sub(/.*:/, "", s); if (s ~ /^[0-9]+$/) { print s; exit } }')
  [ -n "$listen" ] || { echo "no listening port found, so it may not be a server"; return; }
  est=$(run_with_timeout 10 lsof -nP -a -p "$pids" -iTCP -sTCP:ESTABLISHED -Fn 2>/dev/null | awk '/^n/ { print; exit }')
  [ -n "$est" ] && { echo "a browser tab or client is connected to it"; return; }
  cwd=$(proc_cwd "$t")
  case $cwd in "$HOME"/?*) ;; *) echo "its project folder could not be verified"; return ;; esac
  [ -f "$cwd/package.json" ] || { echo "no package.json in its folder"; return; }
  agent=$(proc_agent_ancestor "$t"); [ -n "$agent" ] && { echo "it was started by an AI agent ($agent)"; return; }
  why=$(busy_reason "$t"); [ -n "$why" ] && { echo "$why"; return; }
  case $(project_recent_edits "$cwd" "$AUTO_DEVSERVER_IDLE_MIN") in
    yes) echo "files in its project changed in the last ${AUTO_DEVSERVER_IDLE_MIN} min"; return ;;
    unknown) echo "recent changes in its project could not be checked"; return ;;
  esac
  # Builds, tests and AI agents anywhere else whose folder is inside this project or contains it.
  local work n=0 p kind first wc
  work=$(user_work_procs "$pids")
  while IFS="$TAB" read -r p kind first; do
    [ -n "$p" ] || continue
    n=$((n + 1)); [ "$n" -gt 30 ] && { echo "too many builds/tests/agents running to check them all"; return; }
    wc=$(proc_cwd "$p"); [ -n "$wc" ] || continue
    if path_related "$wc" "$cwd"; then
      if [ "$kind" = agent ]; then echo "an AI agent is working in this project (${first##*/})"; else echo "a build/test is running in the same project (${first##*/})"; fi
      return
    fi
  done <<END_WORK
$work
END_WORK
  printf 'OK\t%s\t%s\n' "$listen" "$cwd"
}

# The only automatic signal: SIGTERM to a verified, unprotected process of an allowed kind.
auto_terminate() {   # kind pid ident -> 0 if SIGTERM was sent; prints the reason otherwise
  check_terminable "$2" || { echo "$T_REASON"; return 1; }
  case $1 in
    ts) case $(printf '%s' "${T_COMM##*/}" | tr 'A-Z' 'a-z') in tsserver*) ;; *) echo "PID $2 is no longer a TypeScript server"; return 1 ;; esac ;;
    dev) ps -ww -o args= -p "$2" 2>/dev/null | awk -v re="$DEV_LAUNCHER_RE" '$0 ~ re { f = 1 } END { exit !f }' || { echo "PID $2 is no longer a dev server launcher"; return 1; } ;;
    *) echo "unknown kind"; return 1 ;;
  esac
  [ -n "$3" ] && [ "$(proc_identity "$2")" = "$3" ] || { echo "PID $2 changed since it was selected"; return 1; }
  kill -TERM "$2" 2>/dev/null || { echo "could not signal PID $2"; return 1; }
  log_event ACTION "automatic SIGTERM to PID $2 (${T_COMM##*/}, $1, idle, high memory pressure)"
  return 0
}

session_auto_note_once() {   # key text: avoid repeating the same explanation every sample
  case $S_AUTO_SEEN in *"|$1|"*) return 0 ;; esac
  S_AUTO_SEEN="$S_AUTO_SEEN|$1|"
  session_note AUTO "$2"
  session_say "Auto: $2."
}

session_auto_schedule() {   # now
  [ -z "$S_AP" ] && [ "$S_MODE" = HIGH ] && auto_rules_on || return 0
  [ -n "$S_IDLE_BASE" ] || return 0
  local now=$1 cands line rank mem key kind t pids since v why
  if [ "$S_AP_N" -ge "$AUTO_MAX_ACTIONS" ]; then
    session_auto_note_once "max" "automatic actions stopped: AUTO_MAX_ACTIONS ($AUTO_MAX_ACTIONS) reached for this session"; return 0
  fi
  if [ "$S_AP_LAST" != 0 ] && [ $((now - S_AP_LAST)) -lt $((AUTO_COOLDOWN_MIN * 60)) ]; then
    session_auto_note_once "cool$S_AP_LAST" "waiting for the ${AUTO_COOLDOWN_MIN}-minute cooldown before any further automatic action"; return 0
  fi
  printf '%s\n' "$S_IDLE_BASE" | awk -F'\t' -v now="$now" -v ti=$((AUTO_TSSERVER_IDLE_MIN * 60)) -v di=$((AUTO_DEVSERVER_IDLE_MIN * 60)) \
    -v pt="$S_PAUSE_TS" -v pd="$S_PAUSE_DEV" -v skip="$S_AP_SKIP" \
    'NF >= 6 && index(skip, " " $1 " ") == 0 && (($4 == "ts" && !pt && now - $3 >= ti) || ($4 == "dev" && !pd && now - $3 >= di)) { f = 1 } END { exit !f }' || return 0
  session_fresh_precise
  cands=$( { printf '%s\n' "$S_IDLE_BASE"; echo '#P'; printf '%s\n' "$PROCS"; } | awk -F'\t' -v now="$now" \
    -v ti=$((AUTO_TSSERVER_IDLE_MIN * 60)) -v di=$((AUTO_DEVSERVER_IDLE_MIN * 60)) -v pt="$S_PAUSE_TS" -v pd="$S_PAUSE_DEV" -v skip="$S_AP_SKIP" '
    $0 == "#P" { p = 1; next }
    !p && NF >= 6 && index(skip, " " $1 " ") == 0 && (($4 == "ts" && !pt && now - $3 >= ti) || ($4 == "dev" && !pd && now - $3 >= di)) { u[$1] = $0; next }
    p && NF >= 12 { m[$1] = $6 }
    END { for (k in u) { split(u[k], f, "\t"); n = split(f[6], q, ","); s = 0; for (i = 1; i <= n; i++) s += m[q[i]]
            printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\n", (f[4] == "ts" ? 1 : 2), s, f[1], f[4], f[5], f[6], f[3] } }' | sort -t "$TAB" -k1,1n -k2,2nr)
  while IFS="$TAB" read -r rank mem key kind t pids since; do
    [ -n "$key" ] || continue
    if [ "$kind" = ts ]; then v=$(ts_verify "$t"); else v=$(dev_verify "$t" "$pids"); fi
    case $v in
      OK*) session_auto_announce "$now" "$kind" "$t" "$mem" "$since" "$pids" "$(printf '%s' "$v" | cut -f2)" "$(printf '%s' "$v" | cut -f3)"; return 0 ;;
      *) why=$v; session_auto_note_once "$key:$why" "left PID $t alone: $why" ;;
    esac
  done <<END_C
$cands
END_C
}

session_auto_announce() {   # now kind pid mem_kb idle_since pids port project
  local ident name what
  ident=$(proc_identity "$3"); [ -n "$ident" ] || return 0
  name=$(printf '%s\n' "$PROCS" | awk -F'\t' -v p="$3" '$1 == p { print $10; exit }')
  S_AP="$2|$3|$ident|$name|$4|$6|$7|$(($1 + AUTO_ACTION_GRACE_SEC))"
  if [ "$2" = ts ]; then what="idle TypeScript server PID $3 (~$(fmt_mb $(($4 / 1024))), idle $(fmt_duration $(($1 - $5)))). Cursor starts a new one when that project needs it"
  else what="idle dev server PID $3 on port $7 ($(tilde_path "$8"), ~$(fmt_mb $(($4 / 1024))), idle $(fmt_duration $(($1 - $5))), no client connected). It is not restarted automatically; rerun your dev command when you need it"; fi
  session_say "Auto in ${AUTO_ACTION_GRACE_SEC}s: stop $what. Press x to cancel."
  notify "In ${AUTO_ACTION_GRACE_SEC}s: stopping an idle $( [ "$2" = ts ] && echo "TypeScript server" || echo "dev server on port $7"). Press x in the manager to cancel."
}

session_auto_cancel() {
  if [ -z "$S_AP" ]; then echo "No automatic action is pending."; return; fi
  local kind=${S_AP%%|*} pid; pid=$(printf '%s' "$S_AP" | cut -d'|' -f2)
  S_AP_SKIP="$S_AP_SKIP$kind:$pid "; S_AP=""
  session_note USER "cancelled the automatic stop of PID $pid ($kind; not selected again this session)"
  echo "Cancelled. PID $pid will not be stopped automatically this session."
}

session_auto_due() {
  [ -n "$S_AP" ] || return 0
  local kind pid ident name mem pids port due now why v base after_since
  IFS='|' read -r kind pid ident name mem pids port due <<END_AP
$S_AP
END_AP
  now=$(now_epoch); [ "$now" -ge "$due" ] || return 0
  S_AP=""
  if [ "$S_MODE" != HIGH ]; then
    session_say "Auto: memory pressure eased; PID $pid left running."
    session_note AUTO "did not stop PID $pid ($kind): pressure eased during the notice period"; return 0
  fi
  base=$(printf '%s\n' "$S_IDLE_BASE" | awk -F'\t' -v k="$kind:$pid" '$1 == k { print $3; exit }')
  session_track_idle "$now"
  after_since=$(printf '%s\n' "$S_IDLE_BASE" | awk -F'\t' -v k="$kind:$pid" '$1 == k { print $3; exit }')
  if [ -z "$base" ] || [ "$after_since" != "$base" ]; then
    S_AP_SKIP="$S_AP_SKIP$kind:$pid "
    session_say "Auto: PID $pid became active or exited; left alone."
    session_note AUTO "did not stop PID $pid ($kind): it became active or exited"; return 0
  fi
  if [ "$kind" = ts ]; then v=$(ts_verify "$pid"); else v=$(dev_verify "$pid" "$pids"); fi
  case $v in OK*) ;; *)
    session_say "Auto: did not stop PID $pid: $v."
    session_note AUTO "did not stop PID $pid ($kind): $v"; return 0 ;;
  esac
  local group=""; [ "$kind" = ts ] && group=$(ts_group_kb "$(printf '%s\n' "$PROCS" | awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }')")
  if why=$(auto_terminate "$kind" "$pid" "$ident"); then
    S_AP_N=$((S_AP_N + 1)); S_AP_LAST=$now
    S_AP_WATCH="2|$kind|$pid|$mem|$(printf '%s\n' "$PROCS" | awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }')|$group|${FREE_PCT:-}|${SWAPOUT_RATE:-}|$port"
    session_say "Auto: sent SIGTERM to $( [ "$kind" = ts ] && echo "idle TypeScript server" || echo "idle dev server") PID $pid (~$(fmt_mb $((mem / 1024)))). Measuring the effect over the next 2 samples."
    session_note AUTO "stopped $( [ "$kind" = ts ] && echo "idle TypeScript server" || echo "idle dev server on port $port") $name (PID $pid, ~$(fmt_mb $((mem / 1024)))) under high memory pressure"
  else
    S_AP_SKIP="$S_AP_SKIP$kind:$pid "
    session_say "Auto: did not stop PID $pid: $why."
    session_note AUTO "did not stop PID $pid ($kind): $why"
  fi
}

ts_group_kb() {   # ppid -> summed memory (KB) of this user's tsservers under that parent
  printf '%s\n' "$PROCS" | awk -F'\t' -v pp="$1" -v me="$CURRENT_UID" 'NF >= 12 && $2 == pp && $3 == me && tolower($10) ~ /^tsserver/ { s += $6 } END { printf "%d", s }'
}

session_auto_ineffective() {   # kind text
  local n
  if [ "$1" = ts ]; then S_INEFF_TS=$((S_INEFF_TS + 1)); n=$S_INEFF_TS; else S_INEFF_DEV=$((S_INEFF_DEV + 1)); n=$S_INEFF_DEV; fi
  if [ "$n" -ge "$AUTO_MAX_INEFFECTIVE" ]; then
    if [ "$1" = ts ]; then S_PAUSE_TS=1; else S_PAUSE_DEV=1; fi
    session_say "Auto result: $2. That is $n ineffective automatic stop(s), so this rule is paused for the rest of the session."
    session_note AFTER "$2; rule paused for this session after $n ineffective stop(s)"
  else
    session_say "Auto result: $2 (ineffective $n of $AUTO_MAX_INEFFECTIVE before this rule pauses)."
    session_note AFTER "$2"
  fi
}

session_check_auto_effect() {
  [ -n "$S_AP_WATCH" ] || return 0
  local n kind pid mem ppid group free0 so0 port after freed df again
  IFS='|' read -r n kind pid mem ppid group free0 so0 port <<END_W
$S_AP_WATCH
END_W
  n=$((n - 1))
  if [ "$n" -gt 0 ]; then S_AP_WATCH="$n|$kind|$pid|$mem|$ppid|$group|$free0|$so0|$port"; return 0; fi
  S_AP_WATCH=""
  df=""; is_uint "$free0" && is_uint "${FREE_PCT:-}" && df=$((FREE_PCT - free0))
  if [ "$kind" = ts ]; then
    session_fresh_precise
    after=$(ts_group_kb "$ppid"); freed=$((group - after))
    if [ "$freed" -lt $((mem / 4)) ]; then
      session_auto_ineffective ts "Cursor restarted the TypeScript server for that window ($(fmt_mb $((group / 1024))) -> $(fmt_mb $((after / 1024)))), little memory was freed"
    else
      session_say "Auto result: that window's TypeScript servers $(fmt_mb $((group / 1024))) -> $(fmt_mb $((after / 1024))); macOS free estimate ${free0:-?}% -> ${FREE_PCT:-?}% (other apps changed too)."
      session_note AFTER "automatic stop of PID $pid: TypeScript servers $(fmt_mb $((group / 1024))) -> $(fmt_mb $((after / 1024))), free estimate ${free0:-?}% -> ${FREE_PCT:-?}%"
    fi
  else
    again=$(run_with_timeout 10 lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fp 2>/dev/null | awk '/^p/ { print substr($0, 2); exit }')
    if [ -n "$again" ]; then
      session_auto_ineffective dev "port $port is served again (PID $again), so the server came back"
    elif [ -n "$df" ] && [ "$df" -lt 2 ] && ! { is_uint "$so0" && is_uint "${SWAPOUT_RATE:-}" && [ "$SWAPOUT_RATE" -le $((so0 / 2)) ] && [ "$so0" -gt 0 ]; }; then
      session_auto_ineffective dev "dev server on port $port stopped, but memory pressure did not measurably improve (free estimate ${free0}% -> ${FREE_PCT}%, swap-out ${so0:-?} -> ${SWAPOUT_RATE:-?} pages/s)"
    else
      session_say "Auto result: dev server on port $port stopped; macOS free estimate ${free0:-?}% -> ${FREE_PCT:-?}%, swap-out ${so0:-?} -> ${SWAPOUT_RATE:-?} pages/s (correlation, not proof)."
      session_note AFTER "automatic stop of the dev server on port $port: free estimate ${free0:-?}% -> ${FREE_PCT:-?}%, swap-out ${so0:-?} -> ${SWAPOUT_RATE:-?} pages/s"
    fi
  fi
}

# Manager-owned temporary files only: state/.times.PID and state/history.tsv.tmp.PID left by
# an interrupted run. Regular files (not symlinks) owned by you, older than 10 minutes, whose
# PID is no longer a running manager. Nothing else is ever deleted automatically.
session_clean_temp() {
  [ "$AUTO_CLEAN_MANAGER_TEMP" = true ] && [ "$DIRS_OK" = 1 ] || return 0
  local f b pid n=0 list
  list=$(find "$STATE_DIR" -maxdepth 1 -type f \( -name '.times.*' -o -name 'history.tsv.tmp.*' \) -user "$CURRENT_UID" -mmin +10 2>/dev/null)
  [ -n "$list" ] || return 0
  while IFS= read -r f; do
    [ "${f%/*}" = "$STATE_DIR" ] && [ -f "$f" ] && [ ! -L "$f" ] || continue
    b=${f##*/}
    case $b in .times.*) pid=${b#.times.} ;; history.tsv.tmp.*) pid=${b#history.tsv.tmp.} ;; *) continue ;; esac
    is_uint "$pid" || continue
    if kill -0 "$pid" 2>/dev/null; then
      case $(ps -o args= -p "$pid" 2>/dev/null) in *mac-performance-manager*|*--work*) continue ;; esac
    fi
    rm -f -- "$f" && n=$((n + 1))
  done <<END_L
$list
END_L
  [ "$n" -gt 0 ] && session_note AUTO "removed $n stale temporary file(s) left in state/ by an interrupted run of the manager"
  return 0
}

session_help() {
  echo "Keys: f free up memory (ranked plan) | s status | t top consumers | d diagnose + choose an action"
  echo "      k stop a dev process | i inspect a PID"
  echo "      c disk cleanup review | a actions this session | r save a report now | n sample now | q stop"
  auto_rules_on && echo "      x cancel a pending automatic action (announced ${AUTO_ACTION_GRACE_SEC}s ahead)"
  [ "$S_INPUT" = pipe ] && echo "      (type the letter and press Enter)"
  echo "While you answer a question, sampling pauses; it resumes right after."
}

session_age() { echo $(( $(now_epoch) - S_LAST_TS )); }

session_status() {
  section "STATUS"
  printf '  %s\n' "$(work_status_line)"
  printf '  Mode %s | sampling every %ss | samples %s | last sample %ss ago\n' "$S_MODE" "$S_INTERVAL" "$S_SAMPLES" "$(session_age)"
  printf '  %s\n' "$VERDICT_REASON"
}

session_top() {
  local before=$S_CACHE_HITS
  session_fresh_precise
  if [ "$S_CACHE_HITS" -gt "$before" ]; then section "TOP CONSUMERS (detailed sample from $(( $(now_epoch) - S_PRECISE_TS ))s ago; reused, no new measurement)"
  else section "TOP CONSUMERS (measured now)"; fi
  echo "  By memory:"; print_proc_table mem 8
  echo "  By CPU:"; print_proc_table cpu 5
  echo "  By application:"
  print_group_table 8
  memory_sum_note
}

session_browser() {
  section "BROWSER MEMORY"
  printf '%s\n' "$PROCS" | awk -F'\t' '$9 == "Brave" || $8 == "Chrome" || $8 ~ /^(Arc|Firefox|Microsoft Edge)$/ { k = $8; n[k]++; m[k] += $6; if ($12 == "renderer") r[k]++ }
    END { for (k in n) { printf "  %-14s ~%.1f GB in %d processes (%d renderers: roughly tabs, extensions and frames)\n", k, m[k] / 1048576, n[k], r[k]; t++ }
          if (!t) print "  No Chromium-based browser found." }'
  echo "  The manager cannot see individual tabs (no API, and it would be private data)."
  echo "  In Brave: Shift+Esc opens its Task Manager; sort by Memory and close tabs you do not need."
  echo "  Memory Saver (Settings > System) unloads background tabs automatically."
}

session_quit_app() {
  quit_app_flow
  case $QA_ACTION in
    asked) session_note USER "approved: asked $QA_NAME to quit"; session_watch_effect "quit $QA_NAME" ;;
    cancelled) session_note USER "declined: quitting $QA_NAME" ;;
  esac
}

session_dev_flow() {
  local rows ports i=0 pid kb cpu name by port cwd n line
  session_fresh_precise
  rows=$(dev_rows | head -n 10)
  if [ -z "$rows" ]; then echo "  No development processes above ${DEV_CANDIDATE_MIN_MB} MB in the latest sample."; return; fi
  ports=$(list_listeners 2>/dev/null)
  section "DEVELOPMENT PROCESSES (latest sample, largest first; memory approximate)"
  while IFS="$TAB" read -r pid kb cpu name by; do
    [ -n "$pid" ] || continue
    i=$((i + 1))
    port=$(printf '%s\n' "$ports" | awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }')
    cwd=$(tilde_path "$(proc_cwd "$pid")")
    printf '  %2d) PID %-6s %-28s %6.0f MB %5.1f%% CPU  up %s%s\n' "$i" "$pid" "$(printf '%s' "$name" | cut -c1-28)" "$(awk -v k="$kb" 'BEGIN { print k / 1024 }')" "$cpu" \
      "$(proc_etime "$pid")" "${port:+  port $port}"
    [ -n "$cwd" ] && [ "$cwd" != / ] && printf '      project: %s\n' "$cwd"
    [ "$by" != "-" ] && printf '      started by: %s\n' "$by"
    printf '      if stopped: %s\n' "$(dev_impact "$name" "$port")"
  done <<EOF
$rows
EOF
  printf '%s\n' "$rows" | awk -F'\t' 'tolower($4) ~ /^tsserver.*semantic/ { n++ } END { if (n > 1)
    printf "  %d TypeScript language servers: usually one per open Cursor window/project. If fewer windows are open,\n  extras may belong to idle workspaces; closing that window or \"TypeScript: Restart TS Server\" is gentler.\n", n }'
  echo "  Low CPU does not mean unused: servers and language servers sit idle between requests and edits."
  echo "  Freed memory is at most roughly the figure shown (shared memory makes it an upper bound)."
  ask "Number to stop gracefully (review + typed 'yes' follow; Enter to cancel): " || return
  n=$(trim "$REPLY_VAL")
  if [ -z "$n" ]; then session_note USER "declined: stopping a development process"; echo "Cancelled. Nothing was sent."; return; fi
  is_uint "$n" || { echo "Not a number. Nothing was sent."; return; }
  line=$(printf '%s\n' "$rows" | awk -v n="$n" 'NR == n')
  [ -n "$line" ] || { echo "No such entry. Nothing was sent."; return; }
  pid=$(printf '%s' "$line" | cut -f1); name=$(printf '%s' "$line" | cut -f4)
  terminate_flow "$pid"
  case $T_ACTION in
    sigterm|sigkill) session_note USER "approved: stopped $name (PID $pid, $T_ACTION)"; session_watch_effect "stop $name" ;;
    left) session_note USER "approved SIGTERM for $name (PID $pid); it kept running and you declined SIGKILL" ;;
    cancelled) session_note USER "declined: stopping $name (PID $pid)" ;;
    refused) session_note USER "refused by safety checks: $name (PID $pid)" ;;
  esac
}

session_diagnose() {
  session_fresh_precise
  section "DIAGNOSIS (memory sample $(session_age)s ago; per-process memory: $(mem_label | sed 's/ MB//'))"
  render_memory_brief
  printf '  Status: %s - %s\n' "$VERDICT" "$VERDICT_REASON"
  if [ "$SWAP_OK" = 1 ] && [ "$SWAP_USED_MB" -ge "$MEM_TOTAL_MB" ] && ! is_uint "${SWAPOUT_RATE:-}"; then
    echo "  Swap rate needs one more sample; swap already in use is history, not proof of a current problem."
  elif [ "$SWAP_OK" = 1 ] && [ "$SWAP_USED_MB" -ge "$MEM_TOTAL_MB" ] && [ "${SWAPOUT_RATE:-0}" -lt "$SWAPOUT_RATE_WARN_PAGES" ]; then
    echo "  Swap in use is large but little is being swapped out now: that is history, not a current problem."
  fi
  echo; echo "  Largest groups:"; print_group_table 6
  local d; d=$(dev_summary); [ -n "$d" ] && echo "  Development processes: $d"
  [ "$VERDICT" = OK ] && echo "  Memory is fine right now; the options below are optional."
  cat <<'EOF'

  Options (sampling pauses until you answer):
    1) Browser memory: how much it uses and how to find heavy tabs     (read-only)
    2) Stop a selected development process: review, typed 'yes', SIGTERM
       Benefit: up to roughly its memory figure. Risk: that server/tool stops.
    3) Quit a selected application gracefully: it can ask you to save
       Benefit: up to roughly the app's memory figure. Risk: you lose its open state.
    4) Ignore and continue monitoring
  Effects show up over the next minute; existing swap shrinks only gradually.
EOF
  ask "Choice [4]: " || return
  case $(trim "$REPLY_VAL") in
    1) session_browser ;;
    2) session_dev_flow ;;
    3) session_quit_app ;;
    *) session_note USER "declined: diagnosis options (kept monitoring)"; echo "Continuing to monitor." ;;
  esac
}

session_inspect() {
  ask "PID to inspect (read-only; Enter to cancel): " || return
  local pid f args; pid=$(trim "$REPLY_VAL")
  [ -n "$pid" ] || return
  is_uint "$pid" || { echo "'$pid' is not a PID."; return; }
  f=$(proc_fields "$pid")
  [ -n "$f" ] || { echo "No process with PID $pid."; return; }
  IFS="$TAB" read -r T_UID T_PPID T_RSS T_CPU T_ETIME T_COMM <<EOF
$f
EOF
  args=$(ps -o args= -p "$pid" 2>/dev/null | redact_args | cut -c1-300)
  section "PROCESS $pid (read-only; nothing is sent to it)"
  printf '  Name:     %s\n  Parent:   %s\n  Memory:   %s (RSS)\n  CPU:      %s%%\n  Running:  %s\n  Command:  %s\n' \
    "${T_COMM##*/}" "$T_PPID" "$(fmt_mb $((T_RSS / 1024)))" "$T_CPU" "$T_ETIME" "$args"
  local cwd; cwd=$(proc_cwd "$pid"); [ -n "$cwd" ] && printf '  Folder:   %s\n' "$(tilde_path "$cwd")"
  if check_terminable "$pid"; then echo "  Could be stopped with k/d (after review and typed confirmation)."
  else echo "  Protected: $T_REASON"; fi
}

session_disk() {
  if [ "$S_MODE" = HIGH ]; then
    echo "Memory pressure is high. A folder scan reads many files and can make the Mac slower for a while."
    ask "Open the disk tools anyway? [y/N] " || return
    case $REPLY_VAL in y|Y|yes) ;; *) session_note AUTO "deferred a disk scan while memory pressure was high"; echo "Deferred. Press c again when pressure is lower."; return ;; esac
  fi
  disk_menu
}

session_actions() {
  section "THIS SESSION"
  echo "  Automatic (the manager's own behaviour):"; printf '%s\n' "${S_AUTO:-none}" | sed 's/^/    /'
  echo "  Your decisions:"; printf '%s\n' "${S_USER:-none}" | sed 's/^/    /'
  echo "  Measured afterwards (correlation, not proof):"; printf '%s\n' "${S_AFTER:-none}" | sed 's/^/    /'
}

prune_reports() {
  ls -1t "$REPORT_DIR"/report-*.txt 2>/dev/null | tail -n +$((REPORT_KEEP + 1)) | while IFS= read -r old; do
    case $old in "$REPORT_DIR"/report-*.txt) rm -f -- "$old" ;; esac
  done
}

session_save_report() {   # text -> prints the file path
  [ "$DIRS_OK" = 1 ] || return 1
  local file; file="$REPORT_DIR/report-session-$(date '+%Y%m%d-%H%M%S').txt"
  printf '%s\n' "$1" > "$file" 2>/dev/null || return 1
  prune_reports
  echo "$file"
}

session_report_now() {
  local text file; session_measure_cpu; text=$(session_report "$(now_epoch)")
  printf '%s\n' "$text"
  if file=$(session_save_report "$text"); then echo "Saved: $file"; else warn "could not save the report."; fi
}

# Names and numbers only: never command lines, paths or arguments.
session_report() {   # now
  local now=$1 n=$S_SAMPLES cpu_ms per="" outmb=0 inmb=0
  [ "$n" -gt 0 ] || n=1
  echo "WORK SESSION SUMMARY"
  printf '  Session:     %s -> %s (%s), %s samples; sampling every %ss (%ss while stable)\n' \
    "$(date -r "$S_START" '+%Y-%m-%d %H:%M')" "$(date -r "$now" '+%H:%M')" "$(fmt_duration $((now - S_START)))" "$S_SAMPLES" "$WORK_INTERVAL_SEC" "$WORK_RELAXED_INTERVAL_SEC"
  [ -n "$S_START_LINE" ] && printf '  At start:    %s\n' "$S_START_LINE"
  printf '  At end:      %s\n' "$(work_status_line)"
  printf '  Pressure:    OK %d%% | WATCH %d%% | HIGH %d%% | CRITICAL %d%% of samples; peak status %s; lowest macOS free estimate %s%%\n' \
    $((S_N_OK * 100 / n)) $((S_N_WATCH * 100 / n)) $((S_N_HIGH * 100 / n)) $((S_N_CRIT * 100 / n)) "$S_PEAK" "${S_MIN_FREE:-?}"
  if [ -n "$S_SWAPOUTS0" ]; then
    outmb=$(( (VM_SWAPOUTS - S_SWAPOUTS0) * VM_PS / 1048576 )); inmb=$(( (VM_SWAPINS - S_SWAPINS0) * VM_PS / 1048576 ))
    printf '  Swap:        %s in use at start, %s at end (peak %s); swapped out %s, swapped in %s; peak swap-out %s pages/s\n' \
      "$(fmt_mb "${S_START_SWAP:-0}")" "$(fmt_mb "$SWAP_USED_MB")" "$(fmt_mb "$S_PEAK_SWAP")" "$(fmt_mb "$outmb")" "$(fmt_mb "$inmb")" "$S_PEAK_SWAPOUT"
  fi
  printf '  Disk:        %s free at end (%s)\n' "$(fmt_mb "$DISK_AVAIL_MB")" "$DISK_STATE"
  if [ -n "$S_WORST_GROUPS" ]; then
    echo "  Largest groups at the lowest free estimate (ps RSS: compressed memory not included, so heavy apps can be undercounted):"
    printf '%s\n' "$S_WORST_GROUPS" | awk -F'\t' 'NF >= 6 { printf "    - %s ~%.1f GB (%d processes, %.0f%% CPU)\n", $1, $4 / 1048576, $3, $6 }'
  fi
  local high_dur=$S_HIGH_TOTAL
  if [ "$S_HIGH_SINCE" != 0 ]; then high_dur=$((high_dur + now - S_HIGH_SINCE)); fi
  if [ "$high_dur" -gt 0 ]; then
    printf '  High pressure: %s total (of %s session time, %d%%)\n' \
      "$(fmt_duration "$high_dur")" "$(fmt_duration $((now - S_START)))" $((high_dur * 100 / (now - S_START + 1)))
  fi
  echo "  Automatic rule summary:"
  printf '    - idle TypeScript servers: %s' "$( [ "$AUTO_STOP_IDLE_TSSERVER" = true ] && echo "enabled (idle >= ${AUTO_TSSERVER_IDLE_MIN} min)" || echo "disabled")"
  if [ "$S_PAUSE_TS" = 1 ]; then printf ' -> PAUSED after %d ineffective stop(s)\n' "$S_INEFF_TS"
  elif [ "$S_AP_N" -ge "$AUTO_MAX_ACTIONS" ]; then printf ' -> stopped: session action limit reached\n'
  else printf '\n'; fi
  printf '    - idle dev servers: %s\n' "$( [ "$AUTO_STOP_IDLE_DEVSERVER" = true ] && echo "enabled (idle >= ${AUTO_DEVSERVER_IDLE_MIN} min)" || echo "disabled")"
  printf '    - actions taken: %d of %d max; ineffective: ts %d, dev %d\n' "$S_AP_N" "$AUTO_MAX_ACTIONS" "$S_INEFF_TS" "$S_INEFF_DEV"
  echo "  Automatic actions (the manager's own behaviour; they do not free memory for other apps):"
  printf '%s\n' "${S_AUTO:-none}" | sed 's/^/    - /'
  cpu_ms=${S_CPU_MS:-}
  if is_uint "$cpu_ms"; then
    per=$((cpu_ms / n))
    printf '    - manager CPU so far: %d.%01d s in total, including %d detailed top samples and your commands (~%d ms per sample on average)\n' \
      $((cpu_ms / 1000)) $((cpu_ms % 1000 / 100)) "$S_PRECISE_N" "$per"
    if [ "$S_RELAXED_SEC" -gt 0 ]; then
      printf '    - relaxed sampling avoided ~%d samples (~%d ms CPU at the measured cost; estimate)\n' \
        $((S_RELAXED_SEC / WORK_INTERVAL_SEC - S_RELAXED_SEC / WORK_RELAXED_INTERVAL_SEC)) \
        $(( (S_RELAXED_SEC / WORK_INTERVAL_SEC - S_RELAXED_SEC / WORK_RELAXED_INTERVAL_SEC) * per ))
    fi
  fi
  [ "$S_CACHE_HITS" -gt 0 ] && printf '    - %d views reused a detailed sample instead of measuring again\n' "$S_CACHE_HITS"
  echo "  Your decisions:"; printf '%s\n' "${S_USER:-none}" | sed 's/^/    - /'
  echo "  Measured after your actions / recoveries (correlation, not proof: other apps changed too):"
  printf '%s\n' "${S_AFTER:-none}" | sed 's/^/    - /'
  if [ -n "$S_ACTION_LOG" ]; then
    echo "  Actions and effects (chronological; each action paired with its measured result):"
    printf '%s\n' "$S_ACTION_LOG" | awk -F'\t' '{
      tag = $1; sub(/^[^\t]*\t/, "")
      if (tag == "AUTO")  printf "    - [auto]  %s\n", $0
      else if (tag == "USER")  printf "    - [user]  %s\n", $0
      else if (tag == "AFTER") printf "      -> %s\n", $0
    }'
  fi
  echo "  Remaining bottlenecks:"
  local any=0
  case $VERDICT in WATCH|HIGH|CRITICAL) echo "    - memory: $VERDICT_REASON"; any=1 ;; esac
  case $DISK_STATE in LOW|CRITICAL) echo "    - disk free space $DISK_STATE ($(fmt_mb "$DISK_AVAIL_MB"))"; any=1 ;; esac
  [ "$SWAP_TREND" = growing ] && { echo "    - swap growing: $(swap_trend_text)"; any=1; }
  [ "$any" = 0 ] && echo "    - none measured at the end"
  echo "  The manager measures and makes safe actions easier; it cannot add RAM. If the workload"
  echo "  is larger than this Mac's $(fmt_mb "$MEM_TOTAL_MB") of RAM, only running less at once (windows, tabs, servers) helps."
}

kill_own_helpers() {   # stops only helpers this shell started, verified by parent PID
  local p=$SLEEP_PID
  SLEEP_PID=""
  [ -n "$p" ] || return 0
  if [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = "$$" ]; then kill -TERM "$p" 2>/dev/null && return 0; fi
  return 0
}

session_command() {   # text
  local c=${1%"${1#?}"}
  is_tty && printf '\r\033[K'
  case $c in
    q|Q) STOP_REQUESTED=1 ;;
    s|S) session_status ;;
    t|T) session_top ;;
    d|D) session_diagnose ;;
    k|K) session_dev_flow ;;
    f|F) free_memory_plan ;;
    i|I) session_inspect ;;
    c|C) session_disk ;;
    a|A) session_actions ;;
    r|R) session_report_now ;;
    n|N) S_FORCE=1 ;;
    x|X) session_auto_cancel ;;
    *) session_help ;;
  esac
}

work_status_line() {
  printf '[%s] %s pressure %s%s | swap %s (%s) | CPU ~%s%% | disk %s free' "$(date '+%H:%M')" "$VERDICT" "$(pressure_text)" \
    "${FREE_PCT:+ ($FREE_PCT% free)}" "$(fmt_mb "$SWAP_USED_MB")" "$SWAP_TREND" "$CPU_TOTAL_PCT" "$(fmt_mb "$DISK_AVAIL_MB")"
}

work_mode() {   # [from_menu]
  local other
  if [ "$DIRS_OK" = 1 ] && ! work_lock acquire; then
    echo "Another work mode is starting right now. Try again in a moment."
    return 1
  fi
  if other=$(pidfile_alive); then
    work_lock release
    echo "Work mode is already running (PID $other). Stop it with: $0 --stop"
    return 1
  fi
  if [ "$DIRS_OK" = 1 ]; then
    # Written whole, then renamed: a reader never sees a PID without its start time.
    { echo "$$"; proc_start "$$"; } > "$PIDFILE.tmp.$$" 2>/dev/null && mv -f -- "$PIDFILE.tmp.$$" "$PIDFILE" && OWN_PIDFILE=1
    rm -f -- "$PIDFILE.tmp.$$"
    work_lock release
  fi
  WORK_ACTIVE=1; STOP_REQUESTED=0
  local now next=0 text file wait_s d
  init_monitor_state; seed_swap_history "$(now_epoch)"; trim_history; collect_uptime; load_model_name
  session_init
  session_clean_temp
  DISK_INTERVAL=$DISK_CHECK_INTERVAL_SEC
  log_event INFO "work mode started (interval ${WORK_INTERVAL_SEC}s)"
  section "WORK SESSION"
  system_line
  echo "Sampling every ${WORK_INTERVAL_SEC}s (${WORK_RELAXED_INTERVAL_SEC}s after ${WORK_RELAX_AFTER_SAMPLES} calm samples; disk every ${DISK_CHECK_INTERVAL_SEC}s)."
  echo "Warnings need ${SUSTAINED_SAMPLES} samples in a row. Apps are never quit and files never deleted automatically."
  printf 'Automatic (under sustained high pressure, %ss notice, x cancels): idle TypeScript servers %s, idle dev servers %s; manager temp cleanup %s.\n' \
    "$AUTO_ACTION_GRACE_SEC" "$( [ "$AUTO_STOP_IDLE_TSSERVER" = true ] && echo "ON (${AUTO_TSSERVER_IDLE_MIN} min)" || echo off)" \
    "$( [ "$AUTO_STOP_IDLE_DEVSERVER" = true ] && echo "ON (${AUTO_DEVSERVER_IDLE_MIN} min)" || echo off)" "$( [ "$AUTO_CLEAN_MANAGER_TEMP" = true ] && echo on || echo off)"
  echo "Events are logged to $(tilde_path "$EVENT_LOG"). Stop with q, Ctrl+C, or --stop from another terminal."
  [ "$NOTIFICATIONS_ENABLED" = true ] && echo "macOS notifications: on, at most one every ${NOTIFY_COOLDOWN_MIN} min."
  [ "$S_INPUT" != none ] && session_help
  echo
  while [ "$STOP_REQUESTED" = 0 ]; do
    now=$(now_epoch)
    if [ "$now" -ge "$next" ] || [ "$S_FORCE" = 1 ]; then
      monitor_tick fast
      [ "$STOP_REQUESTED" = 1 ] && break
      now=$(now_epoch)
      session_record_sample "$now"
      process_events
      S_RECO_PRINTED=0
      if [ -n "$EVENT_LINES" ]; then
        session_say "$EVENT_LINES"
        case $EVENT_LINES in *WARN:*)
          if [ $((now - LAST_RECO_TS)) -ge $((NOTIFY_COOLDOWN_MIN * 60)) ] || [ "$LAST_RECO_TS" = 0 ]; then
            # Advice names apps by size: measure footprints first (RSS misses compressed/swapped memory).
            session_fresh_precise
            LAST_RECO_TS=$now; S_RECO_PRINTED=1; echo "Recommended:"; build_recommendations | sed 's/^/  /'
          fi ;;
        esac
        EVENT_LINES=""
      fi
      session_update_mode "$now"
      if is_tty; then printf '\r\033[K%s' "$(work_status_line)"
      elif [ "$S_FORCE" = 1 ] || [ $((TICKS % 10)) -eq 1 ]; then printf '%s | sample %s\n' "$(work_status_line)" "$S_SAMPLES"; fi
      S_FORCE=0
      next=$((now + S_INTERVAL))
    fi
    now=$(now_epoch); wait_s=$((next - now))
    if [ -n "$S_AP" ]; then d=$(( ${S_AP##*|} - now )); [ "$d" -lt "$wait_s" ] && wait_s=$d; fi
    [ "$wait_s" -lt 0 ] && wait_s=0
    session_wait "$wait_s" || break
    if [ -n "$S_CMD" ]; then session_command "$S_CMD"; S_CMD=""; fi
    session_auto_due
  done
  is_tty && printf '\n'
  if [ -n "$S_AP" ]; then session_note AUTO "pending automatic stop of PID $(printf '%s' "$S_AP" | cut -d'|' -f2) dropped: the session ended first"; S_AP=""; fi
  kill_own_helpers
  session_clean_temp
  [ "$S_INTERVAL" != "$WORK_INTERVAL_SEC" ] && session_note AUTO "temporary sampling interval (${S_INTERVAL}s) ended with the session"
  now=$(now_epoch)
  session_measure_cpu
  text=$(session_report "$now")
  if [ "$SESSION_REPORT_ENABLED" = true ] && file=$(session_save_report "$text"); then text="$text${NL}  Saved: $file"; fi
  section "WORK SESSION SUMMARY"
  printf '%s\n' "$text" | tail -n +2
  log_event INFO "work mode stopped after $(fmt_duration $((now - S_START))) (peak $S_PEAK, peak swap ${S_PEAK_SWAP} MB)"
  remove_own_pidfile
  WORK_ACTIVE=0; STOP_REQUESTED=0
}

stop_work_mode() {
  local pid
  if ! pid=$(pidfile_alive); then
    echo "Work mode is not running."
    # Remove a stale pidfile, but never one that an instance is claiming at this moment.
    if [ "$DIRS_OK" = 1 ] && [ -f "$PIDFILE" ] && work_lock acquire; then
      pidfile_alive >/dev/null || rm -f -- "$PIDFILE"
      work_lock release
    fi
    return 0
  fi
  if is_tty; then
    ask "Stop work mode (PID $pid)? [y/N] " || return 0
    case $REPLY_VAL in y|Y|yes) ;; *) echo "Cancelled."; return 0 ;; esac
  fi
  kill -TERM "$pid" 2>/dev/null && echo "Stop signal sent to work mode (PID $pid). It prints a summary and exits."
}

report_mode() {
  load_model_name
  snapshot_once precise
  local ts file text
  ts=$(date '+%Y%m%d-%H%M%S')
  text=$(build_report)
  printf '%s\n' "$text"
  if [ "$DIRS_OK" = 1 ]; then
    file="$REPORT_DIR/report-$ts.txt"
    if printf '%s\n' "$text" > "$file" 2>/dev/null; then
      printf '\nSaved: %s\n' "$file"
      prune_reports
    else
      warn "could not save report to $REPORT_DIR"
    fi
  fi
}

# Reports contain process NAMES only - never command lines, paths, or arguments.
build_report() {   # runs in a subshell: disabling colours here does not leak
  C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_YEL=""; C_GRN=""; C_CYN=""
  echo "MAC PERFORMANCE REPORT - $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "System:   $(system_line)"
  echo "Memory:   total $(fmt_mb "$MEM_TOTAL_MB") | pressure $(pressure_text) (level ${PRESS_LEVEL:-?}) | macOS free estimate ${FREE_PCT:-?}%"
  echo "          used $(fmt_mb "$MEM_USED_MB") (app $(fmt_mb "$MEM_APP_MB"), wired $(fmt_mb "$MEM_WIRED_MB"), compressed $(fmt_mb "$MEM_COMP_MB")) | cached files $(fmt_mb "$MEM_CACHED_MB")"
  echo "Swap:     $(fmt_mb "$SWAP_USED_MB") used of $(fmt_mb "$SWAP_TOTAL_MB") | trend: $(swap_trend_text) | swap-out now ${SWAPOUT_RATE:-?} pages/s"
  echo "CPU:      $(render_cpu_brief | sed 's/^ *//')"
  echo "Disk:     $(render_disk_brief | sed 's/^ *//')"
  echo "Status:   $VERDICT - $VERDICT_REASON (single measurement; --work detects sustained problems)"
  echo
  echo "Recent swap changes:"; swap_history_summary
  echo
  echo "Top CPU (1 s sample):"; print_proc_table cpu 10 | cut -c1-80
  echo
  echo "Top memory:"; print_proc_table mem 10 | cut -c1-80
  echo
  echo "By application:"; print_group_table 10; memory_sum_note
  echo
  echo "Warnings:"
  local w=0
  case $VERDICT in WATCH|HIGH|CRITICAL) echo "  - Memory: $VERDICT_REASON"; w=1 ;; esac
  case $DISK_STATE in LOW|CRITICAL) echo "  - Disk free space $DISK_STATE"; w=1 ;; esac
  [ "$SWAP_TREND" = growing ] && { echo "  - Swap growing: $(swap_trend_text)"; w=1; }
  if [ "$DIRS_OK" = 1 ] && [ -f "$EVENT_LOG" ]; then
    local cutoff; cutoff=$(date -v-1d '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '1 day ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    local recent; recent=$(tail -n 200 "$EVENT_LOG" | awk -F'\t' -v c="$cutoff" '$2 == "WARN" && (c == "" || $1 >= c) { print "  - " $1 " " $3 }' | tail -n 5)
    [ -n "$recent" ] && { echo "  Logged in the last 24 h:"; printf '%s\n' "$recent"; w=1; }
  fi
  [ "$w" = 0 ] && echo "  None."
  echo
  echo "Recommended actions:"; build_recommendations | sed 's/^/  /'
}

main_menu() {
  while :; do
    init_monitor_state
    collect_memory; collect_pressure; collect_swap; collect_disk; evaluate_state
    printf '\n%sMac Performance Manager %s%s  |  %s  |  swap %s  |  disk %s free\n' "$C_B" "$MPM_VERSION" "$C_RST" \
      "$(badge "$VERDICT") pressure $(pressure_text)${FREE_PCT:+ ($FREE_PCT% free)}" "$(fmt_mb "$SWAP_USED_MB")" "$(fmt_mb "$DISK_AVAIL_MB")"
    cat <<'EOF'
   f) Free up memory: a ranked plan of what to close; you approve each step
   1) Live system overview          8) Development process diagnostics
   2) Memory diagnostics            9) Safe cleanup recommendations
   3) CPU diagnostics              10) Interactive process management
   4) Disk diagnostics             11) Start work mode
   5) Top memory-consuming procs   12) Stop monitoring (work mode)
   6) Top CPU-consuming procs      13) Exit
   7) Cursor diagnostics
EOF
    ask "Select [f, 1-13]: " || return 0
    case $(trim "$REPLY_VAL") in
      f|F) free_memory_plan; pause ;;
      1) live_mode ;;
      2) view_memory; pause ;;
      3) view_cpu; pause ;;
      4) disk_menu ;;
      5) view_top_memory; pause ;;
      6) view_top_cpu; pause ;;
      7) view_cursor; pause ;;
      8) view_dev; pause ;;
      9) cleanup_menu ;;
      10) process_menu ;;
      11) work_mode ;;
      12) stop_work_mode; pause ;;
      13|q|Q|exit) return 0 ;;
      "") ;;
      *) echo "Unknown choice." ;;
    esac
  done
}

print_help() {
  cat <<EOF
Mac Performance Manager $MPM_VERSION - lightweight, safe performance helper for macOS.

Usage:
  ./mac-performance-manager.sh              Interactive dashboard (menu)
  ./mac-performance-manager.sh --live       Live overview (refreshes; q to quit)
  ./mac-performance-manager.sh --work       Work mode: monitor all day, warn on sustained problems
  ./mac-performance-manager.sh --report     Concise report, saved under reports/
  ./mac-performance-manager.sh --once       Print one overview and exit
  ./mac-performance-manager.sh --free       Free up memory: ranked plan, you approve each step
  ./mac-performance-manager.sh --stop       Stop a running work mode (from another terminal)
  ./mac-performance-manager.sh --check-config   Show effective settings and config warnings
  ./mac-performance-manager.sh --help | --version

Options:
  --config FILE   Use FILE instead of config.env next to the script (or set MPM_CONFIG)
  --no-color      Disable colors (NO_COLOR is also respected)

Safety: no sudo, no network, never deletes your files. Every termination you start and every
Trash move is shown in full and needs a typed confirmation. The only automatic stops
are the opt-in AUTO_STOP_IDLE_* rules (off by default): SIGTERM to an idle TypeScript
or dev server under sustained pressure, announced first (x cancels). See README.md.

Exit status: --check-config exits 1 when the configuration has errors.
EOF
}

# =============================================================================
# Signals & main
# =============================================================================
on_signal() {   # name code
  STOP_REQUESTED=1
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  if [ "$WORK_ACTIVE" != 1 ]; then exit "$2"; fi
}

on_exit() {
  local rc=$?
  [ "$EXITING" = 1 ] && return
  EXITING=1
  kill_own_helpers
  restore_terminal
  remove_own_pidfile
  work_lock release
  exit "$rc"
}

main() {
  local mode=interactive cfg=""
  while [ $# -gt 0 ]; do
    case $1 in
      -h|--help) mode=help ;;
      --version) mode=version ;;
      --work) mode=work ;;
      --report) mode=report ;;
      --live) mode=live ;;
      --once) mode=once ;;
      --free) mode=free ;;
      --stop) mode=stop ;;
      --check-config) mode=checkconfig ;;
      --no-color) FORCE_NO_COLOR=1 ;;
      --config) shift; [ $# -gt 0 ] || { echo "Error: --config needs a file" >&2; exit 2; }; cfg=$1 ;;
      --config=*) cfg=${1#--config=} ;;
      *) echo "Error: unknown option '$1' (see --help)" >&2; exit 2 ;;
    esac
    shift
  done
  case $mode in
    help) print_help; return 0 ;;
    version) echo "mac-performance-manager $MPM_VERSION"; return 0 ;;
  esac
  set_defaults
  load_config "$cfg"
  setup_colors
  if [ "$mode" = checkconfig ]; then
    print_config
    [ -z "$CONFIG_WARNINGS" ] || return 1   # every warning is an invalid or ignored setting
    return 0
  fi
  [ -n "$CONFIG_WARNINGS" ] && printf '%s\n' "$CONFIG_WARNINGS" | while IFS= read -r w; do warn "config: $w"; done
  trap on_exit EXIT
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
  trap 'on_signal HUP 129' HUP
  detect_platform
  init_dirs
  case $mode in
    work) work_mode ;;
    report) report_mode ;;
    live) live_mode ;;
    once) load_model_name; snapshot_once precise; collect_uptime; render_overview ;;
    free) free_memory_plan ;;
    stop) stop_work_mode ;;
    interactive) load_model_name; main_menu ;;
  esac
}

init_globals
if [ "${MPM_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
fi
