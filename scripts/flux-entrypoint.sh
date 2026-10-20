#!/bin/bash
# PID 1, and the supervisor of the BeamMP server.
#
# The server runs as a CHILD, never exec, so a stop reaches us first, and a server that ends on
# its own is followed by the next one in place:
#
#   - every start: the BeamMP-Server build (BEAMMP_VERSION, default the newest stable GitHub
#     release, downloaded into the local volume; the build in the image when GitHub cannot be
#     reached), a restore the hub asked for, the built-in FluxAdmin plugin put back, a backup,
#     ServerConfig.toml written from the panel's settings and the deploy's env (flux-beammp apply),
#     then the server with its console on a FIFO and its output on the container's log and a
#     rotated log file
#   - NO AUTHKEY: BeamMP refuses to start without one (it exits after 10 s, measured). Restarting
#     it would only burn the restart budget, so the supervisor says so and waits: the owner adds the
#     key in Deployment Settings, which restarts the container
#   - a watcher: every FLUX_UPDATE_CHECK_HOURS, a newer BeamMP release restarts the server onto it,
#     but only while nobody is playing
#   - SIGTERM/SIGINT from Docker: `exit` on the console (BeamMP kicks the players and stops; there is
#     no world to save, the server keeps no state of its own)
#   - FLUX_RESTART_MAX_ATTEMPTS unplanned restarts inside FLUX_RESTART_WINDOW seconds: the container
#     ends with 42, a server that cannot stay up is the platform's to rebuild or move
#
# Same shape as runonflux/tf2-server-flux and runonflux/dst-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-5}"
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-20}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
FLUX_UPDATE_CHECK_HOURS="${FLUX_UPDATE_CHECK_HOURS:-6}"
beammp() { python3 /opt/flux/fluxbeammp.py "$@"; }

s="${FLUX_SERVER_DIR}"
d="${FLUX_DATA_DIR}"
run="${s}/run"

rm -f "${FLUX_RESTART_MARKER}" "${FLUX_GENERATION_FILE}"
mkdir -p "${s}" "${d}/flux" "${run}" "${FLUX_GAME_LOG_DIR}" "${d}/Resources/Client" "${d}/Resources/Server"
# An older image kept flux.log on the synced data volume: move it here, once.
flux_log_migrate "${FLUX_DATA_DIR}/flux/flux.log"
flux_banner "BeamMP"
set_state() { printf '%s\n' "$1" >"${FLUX_STATE_FILE}"; }
set_state starting

port_raw="${GAME_PORT:-${BEAMMP_PORT:-30814}}"
if ! port="$(flux_valid_port "${port_raw}")"; then
  flux_log "ERROR GAME_PORT='${port_raw}' is not a port from 1024 to 65535; refusing to start"
  exit 42
fi
export GAME_PORT="${port}"
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, port ${port})"

game_pid=""
side_pids=()
game_rc=0
terminating=0
generation=0
restart_history=()

rm -f "${FLUX_CONSOLE_FIFO}"
mkfifo -m 600 "${FLUX_CONSOLE_FIFO}"
# Held open by the supervisor between commands, so the server's stdin never sees an end of file
# while it runs. Closed once the server has shut down: see wait_for_generation.
open_console() { exec 3<>"${FLUX_CONSOLE_FIFO}"; console_open=1; }
close_console() { exec 3>&-; console_open=0; }
open_console

stop_server() {
  [ -n "${game_pid}" ] || return 0
  if ! printf 'exit\n' >&3; then
    flux_log "WARN the console did not take the command; stopping the server with a signal"
    pkill -TERM -x "${FLUX_GAME_PROCESS}" 2>/dev/null
  fi
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested ($1): stopping the server, no restart will follow"
  stop_server
}
trap 'term_handler TERM' TERM
trap 'term_handler INT' INT

# Sleeps $1 seconds in a way a stop interrupts at once (a foreground sleep holds bash's traps).
nap() {
  sleep "$1" &
  wait $!
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    flux_log "backup (every ${FLUX_BACKUP_HOURS}h): $(beammp backup "every ${FLUX_BACKUP_HOURS}h" force 2>&1 | tail -c 300)"
  done
}

# A newer BeamMP release, while nobody is on: the server stops and the next generation downloads
# it. Players are never dropped for an update; with someone on, it waits for the next check.
# shellcheck disable=SC2329  # run in the background below
updater() {
  [ "${FLUX_UPDATE_CHECK_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  local answer players
  while true; do
    sleep $((FLUX_UPDATE_CHECK_HOURS * 3600))
    answer="$(beammp update-available 2>/dev/null)"
    grep -q '"update": true' <<<"${answer}" || continue
    players="$(beammp status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("players") or 0)' 2>/dev/null)"
    if [ "${players:-0}" = "0" ]; then
      flux_log "a new BeamMP-Server release is out (${answer}); nobody is playing, so restarting onto it"
      printf 'planned: BeamMP update\n' >"${FLUX_RESTART_MARKER}"
      flux_console exit || true
    else
      flux_log "a new BeamMP-Server release is out (${answer}); ${players} playing, so it waits"
    fi
  done
}

# The console, line by line: carriage returns and terminal escapes dropped, onto the container's
# output and into the current log file, which is rotated at FLUX_GAME_LOG_MAX_BYTES.
# shellcheck disable=SC2329  # used in a process substitution below
console_writer() {
  local line file bytes=0
  file="${FLUX_GAME_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-console.log"
  : >"${file}"
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    # shellcheck disable=SC2001  # a regex, not a fixed string
    [[ "${line}" == *$'\e'* ]] && line="$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' <<<"${line}")"
    printf '%s\n' "${line}"
    printf '%s\n' "${line}" >>"${file}"
    bytes=$((bytes + ${#line} + 1))
    if [ "${bytes}" -ge "${FLUX_GAME_LOG_MAX_BYTES}" ]; then
      file="${FLUX_GAME_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-console.log"
      : >"${file}"
      bytes=0
      flux_prune "${FLUX_GAME_LOG_DIR}" '*-console.log' "${FLUX_GAME_LOG_KEEP}"
    fi
  done
}

# The image's own plugin, put back as the image ships it: the panel's player list, kick by id and
# bans depend on it.
install_flux_admin() {
  rm -rf "${d}/Resources/Server/FluxAdmin.flux-new"
  cp -r /opt/flux/FluxAdmin "${d}/Resources/Server/FluxAdmin.flux-new" \
    && rm -rf "${d}/Resources/Server/FluxAdmin" \
    && mv "${d}/Resources/Server/FluxAdmin.flux-new" "${d}/Resources/Server/FluxAdmin"
  rm -rf "${d}/flux/plugins-disabled/FluxAdmin"
}

# The JSON field $2 of the JSON text $1 (one level, strings/numbers/bools), or empty.
json_field() {
  python3 -c 'import json,sys
try:
    v = json.loads(sys.argv[1]).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))' "$1" "$2" 2>/dev/null
}

server_bin=""

start_generation() {
  local applied auth answer
  generation=$((generation + 1))
  [ "${console_open}" = "1" ] || open_console
  rm -f "${FLUX_RESTART_MARKER}"
  set_state starting

  # The build: GitHub's newest stable release, or BEAMMP_VERSION, or the image's own.
  set_state updating
  # Warnings go to a file and are logged after: a process substitution here would write its log
  # lines into the command substitution, i.e. into the answer.
  answer="$(beammp server-binary 2>/tmp/flux-server-binary.err)"
  while IFS= read -r line; do flux_log "server: ${line}"; done </tmp/flux-server-binary.err
  server_bin="$(json_field "${answer}" path)"
  [ -x "${server_bin}" ] || server_bin=/opt/beammp/BeamMP-Server
  flux_log "BeamMP-Server $(json_field "${answer}" version) (${server_bin})"
  [ "${terminating}" = "1" ] && return 2
  set_state starting

  # A restore the hub asked for (flux-beammp restore): applied before anything reads the files.
  [ -f "${d}/flux/restore-request" ] && flux_log "restore: $(beammp apply-restore 2>&1 | tail -c 400)"
  # Plugin changes queued while the last server ran (BeamMP aborts when a plugin folder changes
  # under it): applied now, between two servers.
  [ -f "${d}/flux/plugin-ops.json" ] && flux_log "plugins: $(beammp apply-plugin-ops 2>&1 | tail -c 400)"
  install_flux_admin
  flux_log "backup (start): $(beammp backup start 2>&1 | tail -c 300)"

  applied="$(beammp apply 2>&1)"
  flux_log "settings: ${applied}"
  auth="$(json_field "${applied}" authKey)"
  if [ "${auth}" != "ok" ]; then
    set_state needs-key
    if [ "${auth}" = "invalid" ]; then
      flux_log "ERROR BEAMMP_AUTH_KEY does not look like a BeamMP AuthKey (a UUID like 1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f). Copy it again from https://keymaster.beammp.com (Keys) into Deployment Settings."
    else
      flux_log "ERROR no BeamMP AuthKey: BeamMP will not start without one. Get one free at https://keymaster.beammp.com (sign in with Discord, Keys, +, any name, Create, copy the Key) and paste it in Deployment Settings, BEAMMP_AUTH_KEY. The server waits here until then."
    fi
    printf '%s %s\n' "${generation}" "$(date -u +%s)" >"${FLUX_GENERATION_FILE}"
    return 3
  fi

  flux_prune "${FLUX_GAME_LOG_DIR}" '*-console.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  # BeamMP writes its own Server.log in its working directory and never trims it within a run; the
  # console is already captured (and rotated) by console_writer, so its copy goes nowhere.
  rm -f "${run}/Server.log" "${run}/Server.old.log"
  ln -s /dev/null "${run}/Server.log"
  # Plugins read "ServerConfig.toml" and "Resources/..." relative to the working directory
  # (CobaltEssentials and Nickel both do, measured: with the server run elsewhere they failed to
  # load). The working directory is local; these two are links to the data volume.
  ln -sfn "${d}/ServerConfig.toml" "${run}/ServerConfig.toml"
  ln -sfn "${d}/Resources" "${run}/Resources"

  flux_banner "BeamMP"
  flux_log "starting the server (generation ${generation})"
  (
    # The console FIFO's writing end is the supervisor's alone (see wait_for_generation): closed
    # here BEFORE the log pipe below is made, or that pipe's reader inherits a copy of it.
    exec 3>&-
    cd "${run}" || exit 1
    # A CLEAN environment: BeamMP reads BEAMMP_* from its env OVER ServerConfig.toml (TConfig.cpp),
    # so passing the deploy's env through would make the panel's settings unchangeable. Only what
    # it needs, and FLUX_DATA_DIR for the FluxAdmin plugin's bans.
    exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME="${HOME:-/root}" \
      TZ="${TZ:-UTC}" LANG=C.UTF-8 FLUX_DATA_DIR="${d}" \
      "${server_bin}" --config="${d}/ServerConfig.toml" <"${FLUX_CONSOLE_FIFO}" > >(console_writer) 2>&1
  ) &
  game_pid=$!
  set_state running
  # The hub waits for this to change to know a restart is over (never the clocks).
  printf '%s %s\n' "${generation}" "$(date -u +%s)" >"${FLUX_GENERATION_FILE}"
  # None of the children may hold the console FIFO open (fd 3): the server's stdin would never
  # reach its end of file at shutdown.
  backupper 3>&- &
  side_pids=($!)
  updater 3>&- &
  side_pids+=($!)
  return 0
}

sweep_generation() {
  local p
  for p in "${side_pids[@]}"; do kill "${p}" 2>/dev/null; done
  side_pids=()
  pkill -KILL -x "${FLUX_GAME_PROCESS}" 2>/dev/null
  game_pid=""
}

# Waits for the server to end. A requested stop or restart that is not honoured within
# FLUX_STOP_GRACE ends it by force. Sets game_rc to its exit code (137 when it had to be killed).
#
# BEAMMP DOES NOT END AFTER "Shutdown." WHILE ITS STDIN IS OPEN: its console thread sits in a read
# and the exit waits for it (measured on 3.9.3: "Shutdown." logged a second after `exit`, the
# process still there 20 s later, under SIGTERM too). So once that line is in the log the
# supervisor closes its end of the FIFO; the read gets an end of file and the server is gone at once.
wait_for_generation() {
  local asked_at=0 now killed=0 log
  while kill -0 "${game_pid}" 2>/dev/null; do
    nap 1
    if [ "${console_open}" = "1" ]; then
      log="$(flux_game_log)"
      if [ -n "${log}" ] && tail -n 5 "${log}" 2>/dev/null | grep -q '\] Shutdown\.$'; then
        close_console
      fi
    fi
    if [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        pkill -KILL -x "${FLUX_GAME_PROCESS}" 2>/dev/null
        killed=1
      fi
    else
      asked_at=0
    fi
  done
  wait "${game_pid}" 2>/dev/null
  game_rc=$?
  [ "${killed}" = "1" ] && game_rc=137
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" = "3" ]; then
    # No key: idle until Docker stops the container (a new key comes with a redeploy). Reminded
    # hourly in the log, which is what the owner reads.
    while [ "${terminating}" != "1" ]; do
      nap 3600
      [ "${terminating}" = "1" ] || flux_log "still waiting for a BeamMP AuthKey (Deployment Settings, BEAMMP_AUTH_KEY; free at https://keymaster.beammp.com)"
    done
    flux_log "stopped on request (no server was running: no AuthKey)"
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation
  rc="${game_rc}"

  reason=""
  [ -f "${FLUX_RESTART_MARKER}" ] && reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"
  set_state starting

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    exit 0
  fi

  # BeamMP ends with 0 when it was told to (the console's `exit`): a restart someone asked for.
  if [ -z "${reason}" ] && [ "${rc}" = "0" ]; then
    reason="requested: the server was stopped from its console (exit 0)"
  fi
  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  nap "${FLUX_RESTART_BACKOFF}"
done
