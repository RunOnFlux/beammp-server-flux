#!/bin/bash
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t.
#
# No GitHub and no real server: a stand-in BeamMP-Server (a bash script answering the commands the
# hub uses) replaces the build in the image, BEAMMP_VERSION pins that build so nothing is
# downloaded, and the real supervisor runs around it.
set -uo pipefail
export LC_ALL=C

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# --- What the scripts need is in the image -----------------------------------------------------
for tool in python3 pgrep pkill mkfifo timeout tail sed curl; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
# shellcheck disable=SC2016  # expanded by the inner bash
check "the real server runs here" "0" "$(status bash -c '/opt/beammp/BeamMP-Server --version | grep -q "^BeamMP-Server v$(cat /opt/beammp/VERSION)"')"
check "flux-console is on the PATH" "0" "$(status command -v flux-console)"
check "flux-beammp is on the PATH" "0" "$(status command -v flux-beammp)"
check "the FluxAdmin plugin is in the image" "0" "$(status test -f /opt/flux/FluxAdmin/main.lua)"
for script in flux-entrypoint.sh flux-console.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done
check "tomllib (the tests read the config with it)" "0" "$(status python3 -c 'import tomllib')"

# --- The supervisor, around a stand-in server ----------------------------------------------------
# It behaves like BeamMP where it matters: it exits 1 after a moment without an AuthKey in the
# config, refuses to read BEAMMP_* from its environment (the supervisor must clear them), echoes each
# command as "> cmd", answers `list`, `say`, `flux players`, ends with 0 on `exit` and with 139 on
# `crash`.
cp /opt/beammp/BeamMP-Server /tmp/real-server
cat >/opt/beammp/BeamMP-Server <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "BeamMP-Server v$(cat /opt/beammp/VERSION)"; exit 0; }
cfg="${1#--config=}"
env | grep -q '^BEAMMP_' && { echo "[ERROR] BEAMMP_ env leaked into the server"; exit 3; }
grep -q '^AuthKey = "[0-9a-f-]\{36\}"' "${cfg}" || { echo "[ERROR] No AuthKey specified"; sleep 1; exit 1; }
echo "[INFO] BeamMP Server v$(cat /opt/beammp/VERSION) cwd=$(pwd)"
echo "[INFO] map=$(sed -n 's/^Map = //p' "${cfg}") port=$(sed -n 's/^Port = //p' "${cfg}")"
echo "[INFO] Authenticated! Server is now public"
trap 'echo "[INFO] gracefully shutting down via SIGTERM"; echo "[INFO] Shutdown."; cat >/dev/null; exit 0' TERM
while IFS= read -r line; do
  echo "> ${line}"
  case "${line}" in
    list) echo "No players online." ;;
    say\ *) echo "Chat message sent!" ;;
    "flux players") echo 'FLUXJSON {"players":[]}' ;;
    reloadmods) echo "Mods reloaded." ;;
    # Like BeamMP: "Shutdown." is logged, then it ends only when stdin is closed.
    exit) echo "[INFO] Shutdown."; cat >/dev/null; exit 0 ;;
    crash) exit 139 ;;
    *) echo "Error: Unknown command: '${line}'." ;;
  esac
done
STUB
chmod +x /opt/beammp/BeamMP-Server

export FLUX_SERVER_DIR=/tmp/srv FLUX_DATA_DIR=/tmp/data FLUX_RESTART_BACKOFF=1 FLUX_UPDATE_CHECK_HOURS=0
BEAMMP_VERSION="$(cat /opt/beammp/VERSION)"
export BEAMMP_VERSION

# 1. No AuthKey: the supervisor waits, it does not crash-loop.
BEAMMP_NAME='Test Server' GAME_PORT=31000 /opt/flux/flux-entrypoint.sh >/tmp/sup0.log 2>&1 &
sup=$!
check "without a key it says where to get one" "0" "$(status wait_for "grep -q 'keymaster.beammp.com' /tmp/sup0.log" 10)"
check "and waits instead of starting the server" "needs-key" "$(cat /tmp/flux-state)"
check "flux-beammp status says the key is missing" "missing" "$(flux-beammp status | python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"])')"
kill -TERM "${sup}"
wait "${sup}"
check "a stop while waiting exits 0" "0" "$?"

# 2. With a key.
logs=/tmp/srv/logs
BEAMMP_NAME='Test Server' BEAMMP_AUTH_KEY=1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f BEAMMP_MAP=italy BEAMMP_MAX_PLAYERS=40 \
  FLUX_MAX_PLAYERS_CAP=16 GAME_PORT=31000 FLUX_GAME_LOG_MAX_BYTES=400 FLUX_GAME_LOG_KEEP=3 \
  /opt/flux/flux-entrypoint.sh >/tmp/sup.log 2>&1 &
sup=$!
check "the server comes up and its output reaches the log" "0" "$(status wait_for "grep -qh 'Authenticated!' ${logs}/*-console.log 2>/dev/null" 20)"
check "the deploy's env never reaches the server" "0" "$(grep -c 'env leaked' /tmp/sup.log)"
check "the config has the map and the port" "0" "$(status grep -q 'map="/levels/italy/info.json" port=31000' /tmp/sup.log)"
check "the plan's cap holds the players" "1" "$(grep -c '^MaxPlayers = 16$' /tmp/data/ServerConfig.toml)"
check "the server runs in the local volume" "0" "$(status grep -q 'cwd=/tmp/srv/run' /tmp/sup.log)"
check "its own Server.log goes nowhere" "/dev/null" "$(readlink /tmp/srv/run/Server.log)"
check "plugins find the config where they look" "/tmp/data/ServerConfig.toml" "$(readlink /tmp/srv/run/ServerConfig.toml)"
check "and Resources" "/tmp/data/Resources" "$(readlink /tmp/srv/run/Resources)"
check "the FluxAdmin plugin is in place" "0" "$(status test -f /tmp/data/Resources/Server/FluxAdmin/main.lua)"
check "flux-console answers" "0" "$(status grep -q 'No players online.' <<<"$(flux-console list)")"
check "flux-console carries the plugin's JSON" "0" "$(status grep -q 'FLUXJSON' <<<"$(flux-console flux players)")"
check "a backup is made on the first start" "1" "$(find /tmp/data/flux/backups -name '*-beammp.tar.gz' | wc -l)"
check "the generation is published for the hub" "1" "$(cut -d' ' -f1 /tmp/flux-generation)"
check "status reads the key as accepted" "ok running" "$(flux-beammp status | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["auth"], d["state"])')"
check "the version is recorded" "${BEAMMP_VERSION}" "$(cat /tmp/srv/current-version)"

# A map change through the hub's commands: settings, then a restart in place.
python3 -c 'import zipfile; z=zipfile.ZipFile("/tmp/123-ks_nord.zip","w"); z.writestr("levels/ks_nord/info.json","{}"); z.close()'
check "a map mod installs" "0" "$(status flux-beammp mod-install /tmp/123-ks_nord.zip)"
check "the map is set" "0" "$(status flux-beammp set-map ks_nord)"
check "a restart is accepted" "0" "$(status flux-beammp restart 'map change')"
check "the next server runs on the new map" "0" "$(status wait_for "grep -q 'map=\"/levels/ks_nord/info.json\"' /tmp/sup.log && test \"\$(cut -d' ' -f1 /tmp/flux-generation)\" = 2" 20)"
check "the restart is not counted as a crash" "0" "$(grep -c 'restarts within' /tmp/sup.log)"

# A plugin with a server running: queued, then applied between two servers.
python3 -c 'import zipfile; z=zipfile.ZipFile("/tmp/456-Racing.zip","w"); z.writestr("Racing/main.lua","print(1)"); z.close()'
check "a plugin install with the server up is queued" "True" "$(flux-beammp plugin-install /tmp/456-Racing.zip | python3 -c 'import json,sys; print(json.load(sys.stdin)["queued"])')"
check "and not yet in Resources/Server" "1" "$(status test -d /tmp/data/Resources/Server/Racing)"
check "applying restarts the server" "0" "$(status flux-beammp plugins-apply)"
check "the plugin is installed between the two servers" "0" "$(status wait_for "test -f /tmp/data/Resources/Server/Racing/main.lua && test \"\$(cut -d' ' -f1 /tmp/flux-generation)\" = 3" 20)"

# A restore through the hub's command.
first="$(basename "$(find /tmp/data/flux/backups -name '*-beammp.tar.gz' | sort | head -1)")"
flux-beammp ban '{"name": "Rammer"}' >/dev/null
check "a restore is accepted" "0" "$(status flux-beammp restore "${first}")"
check "the server restarts for it and the ban list is back as it was" "0" "$(status wait_for "grep -q 'restore: ' /tmp/sup.log && ! grep -q Rammer /tmp/data/flux/bans.json 2>/dev/null && test \"\$(cut -d' ' -f1 /tmp/flux-generation)\" = 4" 20)"

for n in 1 2 3 4 5 6 7 8; do flux-console say "filler line number ${n} to roll the log over" >/dev/null; done
check "the console log is rotated and pruned" "0" "$(status test "$(find "${logs}" -name '*-console.log' | wc -l)" -le 3)"

# A crash: restarted in place.
flux-console crash >/dev/null
check "a crash is restarted in place" "0" "$(status wait_for "grep -q 'restarting the server in place' /tmp/sup.log && grep -q 'exit 139' /tmp/sup.log" 10)"
check "and the new server comes up" "0" "$(status wait_for "grep -q 'generation 5' /tmp/sup.log" 10)"
sleep 2

kill -TERM "${sup}"
wait "${sup}"
check "a stop exits 0" "0" "$?"
check "a stop is a console exit" "0" "$(status grep -q 'stopped on request (server exited 0)' /tmp/sup.log)"
check "and not a forced one" "0" "$(grep -c 'has not; ending it' /tmp/sup.log)"
check "nothing is left running" "1" "$(status pgrep -x BeamMP-Server)"

# --- flux.log is local; the banner ----------------------------------------------------------------
fl_srv=/tmp/srv
check "flux.log is on the install volume" "0" "$(status test -s "${fl_srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "/tmp/data/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q 'BeamMP server image by FluxCloud - https://runonflux.com' /tmp/sup.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${fl_srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/sup.log)" -ge 2 ] && echo 1 || echo 0)"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
