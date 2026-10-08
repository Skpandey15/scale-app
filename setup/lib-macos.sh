#!/usr/bin/env bash
# Shared helpers for install-macos.sh / cleanup-macos.sh (sourced, not run directly).
# Must stay compatible with bash 3.2, the version macOS ships: no associative arrays, mapfile, ${var,,}, &>>.

if [ -t 1 ]; then
  C_STEP=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_DIM=$'\033[90m'; C_PLAN=$'\033[35m'; C_OFF=$'\033[0m'
else
  C_STEP=''; C_OK=''; C_WARN=''; C_DIM=''; C_PLAN=''; C_OFF=''
fi

step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_OFF"; }
ok()   { printf '    %s[ok]%s %s\n' "$C_OK" "$C_OFF" "$1"; }
skip() { printf '    %s[skip]%s %s\n' "$C_DIM" "$C_OFF" "$1"; }
warn() { printf '    %s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$1"; }
# done_ok: report success of a step run via `run`; stays silent in --dry-run (the plan line already said what would happen).
done_ok() { if [ "${DRY_RUN:-0}" != 1 ]; then ok "$1"; fi; }
plan() { printf '    %s[dry-run] would:%s %s\n' "$C_PLAN" "$C_OFF" "$1"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_WARN" "$C_OFF" "$1" >&2; exit 1; }

# run <command...>: execute, or just describe it in --dry-run mode.
run() {
  if [ "${DRY_RUN:-0}" = 1 ]; then plan "$*"; return 0; fi
  "$@"
}

# run_quiet <command...>: like run, but hides the command's own output. (Redirecting `run ... >/dev/null` would also hide the
# dry-run description, so quiet steps would vanish from a preview.)
run_quiet() {
  if [ "${DRY_RUN:-0}" = 1 ]; then plan "$*"; return 0; fi
  "$@" >/dev/null 2>&1
}

# confirm <question>: true if --yes, in a dry run, or the user answers y.
confirm() {
  if [ "${ASSUME_YES:-0}" = 1 ] || [ "${DRY_RUN:-0}" = 1 ]; then return 0; fi
  printf '%s [y/N] ' "$1"
  read -r answer || answer=n
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---- state file: records what the installer added so cleanup only removes that ----
STATE_FILE="${SCALE_STATE_FILE:-$HOME/.scale-app-setup-state}"
state_add() {  # state_add KEY VALUE
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  touch "$STATE_FILE"
  grep -qx "$1=$2" "$STATE_FILE" 2>/dev/null || echo "$1=$2" >> "$STATE_FILE"
}
state_list() { # state_list KEY -> values, one per line
  if [ -f "$STATE_FILE" ]; then sed -n "s/^$1=//p" "$STATE_FILE"; fi
  return 0
}
state_has() { [ -f "$STATE_FILE" ] && grep -qx "$1=$2" "$STATE_FILE"; }
state_remove() { # state_remove KEY VALUE
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  [ -f "$STATE_FILE" ] || return 0
  grep -vx "$1=$2" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# ---- hardware / OS facts (with Linux fallbacks so the scripts can be dry-run tested off a Mac) ----
mem_gb() {
  b=$(sysctl -n hw.memsize 2>/dev/null || true)
  if [ -z "$b" ] && [ -r /proc/meminfo ]; then kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo); b=$((kb * 1024)); fi
  echo $(( ${b:-0} / 1073741824 ))
}
cpu_count() { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4; }
macos_major() { v=$(sw_vers -productVersion 2>/dev/null || echo 0); echo "${v%%.*}"; }

load_brew() {  # make `brew` available in this shell if it is installed in a standard location
  if command -v brew >/dev/null 2>&1; then return 0; fi
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$b" ]; then eval "$("$b" shellenv)"; return 0; fi
  done
  return 1
}

docker_ready() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
cluster_exists() { command -v k3d >/dev/null 2>&1 && k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
