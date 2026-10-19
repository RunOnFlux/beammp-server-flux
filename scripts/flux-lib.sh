#!/bin/bash
# Shared helpers for the BeamMP image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, GitHub or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. The data (synced, the g: mount): ServerConfig.toml, Resources/ (the client mods players
# download and the server's Lua plugins) and our flux/ (the panel's settings, bans, backups, log).
# The server dir (local, the ml: mount): the BeamMP-Server binaries GitHub gave us, the working
# directory the server runs in, and the console logs.
# ---------------------------------------------------------------------------------------------
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/beammp/data}"
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/beammp/server}"
FLUX_LOG="${FLUX_LOG:-${FLUX_DATA_DIR}/flux/flux.log}"
FLUX_LOG_MAX_LINES="${FLUX_LOG_MAX_LINES:-2000}"
# The console logs: on the LOCAL volume, they churn all day and Syncthing would copy every line.
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_SERVER_DIR}/logs}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-5}"
# One console log is capped at this many bytes; past it the server goes on in a fresh one.
FLUX_GAME_LOG_MAX_BYTES="${FLUX_GAME_LOG_MAX_BYTES:-10000000}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-BeamMP-Server}"
# The server's console is its stdin, a plain FIFO (BeamMP reads lines from a pipe and answers on
# stdout, no terminal needed, measured on 3.9.3). The supervisor holds it open; flux-console writes
# one command into it.
FLUX_CONSOLE_FIFO="${FLUX_CONSOLE_FIFO:-/tmp/flux-console}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
# "<generation> <epoch it started>": the hub's way to see a restart is over.
FLUX_GENERATION_FILE="${FLUX_GENERATION_FILE:-/tmp/flux-generation}"
# What the supervisor is doing, for `flux-beammp status`: starting | running | needs-key | updating.
FLUX_STATE_FILE="${FLUX_STATE_FILE:-/tmp/flux-state}"

flux_log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
  printf '%s\n' "${line}"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_trim_file "${FLUX_LOG}" "${FLUX_LOG_MAX_LINES}"
  fi
}

# Keeps the last $2 lines of $1. Checked cheaply first: most calls change nothing.
flux_trim_file() {
  local file="$1" max="$2" lines
  lines="$(wc -l <"${file}" 2>/dev/null || echo 0)"
  if [ "${lines}" -gt $((max + max / 10)) ]; then
    tail -n "${max}" "${file}" >"${file}.tmp" 2>/dev/null && mv "${file}.tmp" "${file}"
  fi
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = GAME_PORT. Prints it, or returns 1 for a value that is not a usable port.
flux_valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1024 ] && [ "${value}" -le 65535 ] || return 1
  printf '%s' "${value}"
}

# $1 = a BeamMP AuthKey. The Keymaster hands out a UUID (36 characters, 8-4-4-4-12 hex); the
# server itself only warns about a key of another length, then the backend refuses it.
flux_valid_auth_key() {
  [[ "${1}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

# ---------------------------------------------------------------------------------------------
# Server versions: GitHub releases of BeamMP/BeamMP-Server, tags like v3.9.3.
# ---------------------------------------------------------------------------------------------

# $1 = a tag or a version ("v3.9.3", "3.9.3"). Prints 3.9.3, or returns 1.
flux_version_of() {
  local v="${1#v}"
  [[ "${v}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  printf '%s' "${v}"
}

# $1, $2 = versions. Returns 0 when $1 is newer than $2.
flux_version_newer() {
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    [ "$((10#${a[i]:-0}))" -gt "$((10#${b[i]:-0}))" ] && return 0
    [ "$((10#${a[i]:-0}))" -lt "$((10#${b[i]:-0}))" ] && return 1
  done
  return 1
}

# $1 = BEAMMP_VERSION (empty or "latest" = follow the newest stable release; "3.9.3" = that one).
# Prints "latest" or the pinned version; returns 1 for anything else.
flux_version_wanted() {
  local v="${1,,}"
  if [ -z "${v}" ] || [ "${v}" = "latest" ]; then
    printf 'latest'
    return 0
  fi
  flux_version_of "${v}"
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. One that was asked for (the console's `exit`, a restore, a
# settings change, an update) is the plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Rotation of the console logs.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# ---------------------------------------------------------------------------------------------
# The running server.
# ---------------------------------------------------------------------------------------------

# The newest console log the supervisor writes.
flux_game_log() {
  # shellcheck disable=SC2012  # our own file names, no spaces
  ls -t "${FLUX_GAME_LOG_DIR}"/*-console.log 2>/dev/null | head -1
}

flux_game_pid() {
  pgrep -x "${FLUX_GAME_PROCESS}" 2>/dev/null | head -1
}

# $1 = one console command. Written into the server's stdin; returns 1 when nothing is reading
# it (no server running), without blocking.
flux_console() {
  local cmd="$1"
  [ -p "${FLUX_CONSOLE_FIFO}" ] || return 1
  [ -n "$(flux_game_pid)" ] || return 1
  # One line, no control characters: it is typed into the server's console.
  cmd="${cmd//[$'\r\n']/ }"
  # shellcheck disable=SC2016  # expanded by the inner bash, from its own arguments
  timeout 2 bash -c 'printf "%s\n" "$1" >"$2"' _ "${cmd}" "${FLUX_CONSOLE_FIFO}"
}

# $1 = a console log line. Prints what it says about the AuthKey, or nothing:
#   ok        "Authenticated! ..." / "Resumed authenticated session! ..."
#   refused   "Backend REFUSED the auth key. Reason: ..."
#   missing   "No AuthKey specified ..."
flux_auth_state_of_line() {
  case "$1" in
    *"Authenticated!"* | *"Resumed authenticated session!"*) printf 'ok' ;;
    *"Backend REFUSED the auth key"*) printf 'refused' ;;
    *"No AuthKey specified"*) printf 'missing' ;;
  esac
  return 0
}
