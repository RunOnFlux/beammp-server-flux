#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and fluxbeammp.py. No Docker, no GitHub, no server.
# Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

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
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- flux-lib.sh -------------------------------------------------------------------------------
check "30814 is a port" "30814" "$(flux_valid_port 30814)"
check "port 80 is refused" "1" "$(status flux_valid_port 80)"
check "a word is not a port" "1" "$(status flux_valid_port abc)"
check "an AuthKey is a UUID" "0" "$(status flux_valid_auth_key 1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f)"
check "a short key is not" "1" "$(status flux_valid_auth_key 1a2b3c4d)"
check "a version from a tag" "3.9.3" "$(flux_version_of v3.9.3)"
check "a tag that is not a version" "1" "$(status flux_version_of latest)"
check "3.10.0 is newer than 3.9.3" "0" "$(status flux_version_newer 3.10.0 3.9.3)"
check "3.9.3 is not newer than 3.9.3" "1" "$(status flux_version_newer 3.9.3 3.9.3)"
check "empty means latest" "latest" "$(flux_version_wanted '')"
check "a pin" "3.9.2" "$(flux_version_wanted 3.9.2)"
check "old restarts age out" "900 950" "$(flux_restarts_in_window 1000 200 100 700 900 950)"
check "a requested stop is not counted" "1" "$(status flux_restart_counts 'requested: restore x')"
check "an update is not counted" "1" "$(status flux_restart_counts 'planned: BeamMP update')"
check "a crash is counted" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "keeps the newest" $'c\nd' "$(flux_files_to_prune 2 a b c d)"
check "an accepted key in the log" "ok" "$(flux_auth_state_of_line '[INFO] Authenticated! Server is now public')"
check "a refused key in the log" "refused" "$(flux_auth_state_of_line '[ERROR] Backend REFUSED the auth key. Reason: Your key is invalid.')"

# --- fluxbeammp.py: the decisions, imported --------------------------------------------------------
py() { env -i PATH="${PATH}" FLUX_DATA_DIR="${tmp}/data" FLUX_SERVER_DIR="${tmp}/server" python3 -I -c "
import sys; sys.path.insert(0, 'scripts')
import fluxbeammp as b
$1"; }
check "a bare folder becomes a map path" "/levels/italy/info.json" "$(py 'print(b.norm_map("italy"))')"
check "a path without its slash" "/levels/utah/info.json" "$(py 'print(b.norm_map("levels/utah/info.json"))')"
check "a path that leaves the folder is not a map" "None" "$(py 'print(b.norm_map("/levels/../etc/info.json"))')"
check "dots are not a map" "None" "$(py 'print(b.norm_map("/levels/../info.json"))')"
check "a map path with a command in it is not a map" "None" "$(py 'print(b.norm_map("/levels/x\"; rm/info.json"))')"
check "stock maps are available" "True" "$(py 'print(b.map_available("/levels/west_coast_usa/info.json", []))')"
check "a map from an enabled mod is available" "True" "$(py 'print(b.map_available("/levels/ks_nord/info.json", [{"enabled": True, "maps": ["ks_nord"]}]))')"
check "a map from a disabled mod is not" "False" "$(py 'print(b.map_available("/levels/ks_nord/info.json", [{"enabled": False, "maps": ["ks_nord"]}]))')"

# The changed-env rule: a deploy value lands when it changed, and leaves a panel change alone when not.
check "the first start takes the env" "{'Name': 'A', 'MaxPlayers': 16}" "$(py 'print(b.merge_env({}, {}, {"BEAMMP_NAME": "A", "BEAMMP_MAX_PLAYERS": "16"})[0])')"
check "an unchanged env leaves the panel's value" "{'Name': 'Panel'}" "$(py 'print(b.merge_env({"Name": "Panel"}, {"BEAMMP_NAME": "A"}, {"BEAMMP_NAME": "A"})[0])')"
check "a changed env wins" "{'Name': 'B'}" "$(py 'print(b.merge_env({"Name": "Panel"}, {"BEAMMP_NAME": "A"}, {"BEAMMP_NAME": "B"})[0])')"
check "an empty env changes nothing" "{'Name': 'Panel'}" "$(py 'print(b.merge_env({"Name": "Panel"}, {}, {"BEAMMP_NAME": ""})[0])')"
check "booleans from env" "{'Private': True}" "$(py 'print(b.merge_env({}, {}, {"BEAMMP_PRIVATE": "true"})[0])')"
check "the cap holds MaxPlayers" "12" "$(py 'print(b.effective_settings({"MaxPlayers": 40}, 12)[0]["MaxPlayers"])')"
check "a bad value falls back to the default" "1" "$(py 'print(b.effective_settings({"MaxCars": "lots"})[0]["MaxCars"])')"

toml="$(py 'print(b.render_config(b.effective_settings({"Name": "My \"Best\" Server", "Map": "/levels/italy/info.json"})[0], "1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f", 31000))')"
check "the name is escaped" "1" "$(grep -c '^Name = "My \\"Best\\" Server"$' <<<"${toml}")"
check "the port is the one given" "1" "$(grep -c '^Port = 31000$' <<<"${toml}")"
check "the key is written" "1" "$(grep -c '^AuthKey = "1a2b3c4d-' <<<"${toml}")"
check "resources are relative, as plugins expect" "1" "$(grep -c '^ResourceFolder = "Resources"$' <<<"${toml}")"
check "the TOML parses" "Italy-ok" "$(python3 -c 'import sys,tomllib; d=tomllib.loads(sys.stdin.read()); print("Italy-ok" if d["General"]["Map"]=="/levels/italy/info.json" and d["General"]["Private"] is False else "bad")' <<<"${toml}")"

check "a whole Resources folder" "('resources', 'Resources/')" "$(py 'print(b.plugin_layout(["Resources/Server/Nickel/main.lua", "Resources/Client/nickel.zip"]))')"
check "Server/ and Client/ at the top" "('resources', '')" "$(py 'print(b.plugin_layout(["Server/BJ/main.lua", "Client/bj.zip"]))')"
check "a GitHub source zip around a Resources folder" "('resources', 'BeamJoy-main/Resources/')" "$(py 'print(b.plugin_layout(["BeamJoy-main/README.md", "BeamJoy-main/Resources/Server/BJ/main.lua"]))')"
check "one plugin folder" "('folder', '')" "$(py 'print(b.plugin_layout(["CobaltEssentials/main.lua", "CobaltEssentials/lua/x.lua"]))')"
check "loose files" "('loose', '')" "$(py 'print(b.plugin_layout(["main.lua", "lib/util.lua"]))')"
check "keeps the newest backups, and one older than a day" "['b', 'c']" "$(py 'print(b.backups_to_prune([{"name":"a","created":1000000},{"name":"b","created":999990},{"name":"c","created":999980},{"name":"d","created":900000}], 1, 1000000))')"

# --- fluxbeammp.py: the commands, on a scratch data volume ---------------------------------------
data="${tmp}/data"
bm() { env -i PATH="${tmp}/bin:${PATH}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${tmp}/server" FLUX_GENERATION_FILE="${tmp}/gen" FLUX_RESTART_MARKER="${tmp}/marker" FLUX_STATE_FILE="${tmp}/state" "$@" python3 -I scripts/fluxbeammp.py "${bm_args[@]}"; }
run() { bm_args=("$@"); bm; }
runenv() { local e=(); while [ "$1" != "--" ]; do e+=("$1"); shift; done; shift; bm_args=("$@"); bm "${e[@]}"; }
jq1() { python3 -c 'import json,sys; d=json.load(sys.stdin); exec(sys.argv[1])' "$1"; }
# A stand-in flux-console that finds no server (the commands then work on the files alone).
mkdir -p "${tmp}/bin" && printf '#!/bin/sh\nexit 1\n' >"${tmp}/bin/flux-console" && chmod +x "${tmp}/bin/flux-console"

check "apply without a key says so" "missing" "$(runenv BEAMMP_NAME=Hello -- apply | jq1 'print(d["authKey"])')"
check "and still writes the settings" "Hello" "$(jq1 'print(d["Name"])' <"${data}/flux/settings.json")"
check "apply with a key" "ok" "$(runenv BEAMMP_NAME=Hello BEAMMP_AUTH_KEY=1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f GAME_PORT=31001 -- apply | jq1 'print(d["authKey"])')"
check "the config has the key and the port" "2" "$(grep -cE '^(AuthKey = "1a2b|Port = 31001)' "${data}/ServerConfig.toml")"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["Name"]="From the panel"; json.dump(d, open(p,"w"))' "${data}/flux/settings.json"
runenv BEAMMP_NAME=Hello BEAMMP_AUTH_KEY=1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f -- apply >/dev/null
check "a panel change survives a restart with the same env" "1" "$(grep -c '^Name = "From the panel"' "${data}/ServerConfig.toml")"
runenv BEAMMP_NAME=Renamed BEAMMP_AUTH_KEY=1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f -- apply >/dev/null
check "a deploy change lands" "1" "$(grep -c '^Name = "Renamed"' "${data}/ServerConfig.toml")"
check "a bad key is called invalid" "invalid" "$(runenv BEAMMP_AUTH_KEY=nope -- apply | jq1 'print(d["authKey"])')"
check "the plan's cap" "12" "$(runenv BEAMMP_MAX_PLAYERS=64 FLUX_MAX_PLAYERS_CAP=12 -- apply | jq1 'print(d["maxPlayers"])')"

# Mods
python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("levels/ks_nord/info.json","{}"); z.writestr("levels/ks_nord/main.level.json","{}"); z.close()' "${tmp}/1700000000000-ks_nord.zip"
check "a mod installs, the upload prefix dropped" "ks_nord.zip ['ks_nord']" "$(run mod-install "${tmp}/1700000000000-ks_nord.zip" | jq1 'print(d["mod"], d["maps"])')"
check "its map is offered" "/levels/ks_nord/info.json" "$(run files | jq1 'print(d["maps"]["modded"][0]["path"])')"
check "the map can be set" "0" "$(status run set-map ks_nord)"
check "a map no mod has is refused" "2" "$(status run set-map /levels/nowhere/info.json)"
check "a mod is turned off" "False" "$(run mod-enable ks_nord.zip off | jq1 'print(d["enabled"])')"
check "and is out of Resources/Client" "1" "$(status test -f "${data}/Resources/Client/ks_nord.zip")"
check "the start map is now unavailable" "False" "$(run files | jq1 'print(d["mapAvailable"])')"
run mod-enable ks_nord.zip on >/dev/null
printf 'not a zip' >"${tmp}/bad.zip"
check "a file that is not a zip is refused" "2" "$(status run mod-install "${tmp}/bad.zip")"
check "a path is not a mod name" "2" "$(status run mod-remove '../ServerConfig.toml')"

printf '{\n    "ks_nord.zip": {"protected": true, "hash": "x", "filesize": 1, "lastwrite": 1}\n}\n}' >"${data}/Resources/Client/mods.json"
check "a mods.json BeamMP left with a tail is read" "True" "$(run files | jq1 'print([m for m in d["mods"] if m["file"]=="ks_nord.zip"][0]["protected"])')"
check "and written back clean" "0" "$(status python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${data}/Resources/Client/mods.json")"

# Plugins
python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("Resources/Server/Racing/main.lua","print(1)"); z.writestr("Resources/Client/racing_ui.zip","PK"); z.close()' "${tmp}/1700000000000-racing.zip"
check "a plugin with its client mod" "['Racing'] ['racing_ui.zip']" "$(run plugin-install "${tmp}/1700000000000-racing.zip" | jq1 'print(d["plugins"], d["mods"])')"
mkdir -p "${data}/Resources/Server/Racing/data" && printf 'records' >"${data}/Resources/Server/Racing/data/records.json"
run plugin-install "${tmp}/1700000000000-racing.zip" >/dev/null
check "an update keeps what the plugin wrote" "records" "$(cat "${data}/Resources/Server/Racing/data/records.json")"
python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("main.lua","print(1)"); z.close()' "${tmp}/1700000000000-Loose.zip"
check "loose files are named after the archive" "['Loose']" "$(run plugin-install "${tmp}/1700000000000-Loose.zip" | jq1 'print(d["plugins"])')"
python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("../../evil.lua","x"); z.close()' "${tmp}/evil.zip"
check "an archive that climbs out is refused" "2" "$(status run plugin-install "${tmp}/evil.zip")"
python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("car/jbeam.json","x"); z.writestr("readme.txt","x"); z.close()' "${tmp}/car.zip"
check "a car mod in the plugins tab is refused" "2" "$(status run plugin-install "${tmp}/car.zip")"
check "a plugin is turned off" "False" "$(run plugin-enable Racing off | jq1 'print(d["enabled"])')"
mkdir -p "${data}/Resources/Server/FluxAdmin"
check "the built-in plugin stays on" "2" "$(status run plugin-enable FluxAdmin off)"
check "the built-in plugin is marked" "True" "$(run files | jq1 'print([p for p in d["plugins"] if p["name"]=="FluxAdmin"][0]["builtin"])')"
check "only GitHub links install" "2" "$(status run plugin-install-url https://example.com/x.zip)"
# With a server running (the state file says so, pgrep finds the process), plugin changes queue.
mkdir -p "${tmp}/bin2" && printf '#!/bin/sh\nexit 0\n' >"${tmp}/bin2/pgrep" && chmod +x "${tmp}/bin2/pgrep"
printf 'running\n' >"${tmp}/state"
runlive() { bm_args=("$@"); env -i PATH="${tmp}/bin2:${tmp}/bin:${PATH}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${tmp}/server" FLUX_GENERATION_FILE="${tmp}/gen" FLUX_RESTART_MARKER="${tmp}/marker" FLUX_STATE_FILE="${tmp}/state" python3 -I scripts/fluxbeammp.py "${bm_args[@]}"; }
check "a removal with a server running is queued" "True" "$(runlive plugin-remove Loose | jq1 'print(d["queued"])')"
check "and the folder is untouched" "0" "$(status test -d "${data}/Resources/Server/Loose")"
check "an install is queued too" "True" "$(runlive plugin-install "${tmp}/1700000000000-racing.zip" | jq1 'print(d["queued"])')"
check "files lists what is queued" "['install:Racing', 'remove:Loose']" "$(runlive files | jq1 'print(sorted(o["op"]+":"+o["name"] for o in d["pendingPlugins"]))')"
check "an install then a switch-off are both kept" "['install:Racing', 'enable:Racing']" "$(runlive plugin-enable Racing off >/dev/null; runlive files | jq1 'print([o["op"]+":"+o["name"] for o in d["pendingPlugins"] if o["name"]=="Racing"])')"
check "discarding drops the queue" "[]" "$(runlive plugins-discard >/dev/null; runlive files | jq1 'print(d["pendingPlugins"])')"
runlive plugin-enable Racing on >/dev/null
check "the supervisor applies the queue" "['on Racing']" "$(rm -f "${tmp}/state"; run apply-plugin-ops | jq1 'print(d["applied"])')"
check "the plugin is on" "0" "$(status test -d "${data}/Resources/Server/Racing")"

# Bans
check "a ban by account id" "1" "$(run ban '{"name": "Speedy", "beammp": "4242", "reason": "ramming"}' | jq1 'print(len(d["bans"]))')"
check "banning the same account again replaces it" "1" "$(run ban '{"name": "Speedy2", "beammp": "4242"}' | jq1 'print(len(d["bans"]))')"
check "a ban by IP" "2" "$(run ban '{"ip": "203.0.113.4"}' | jq1 'print(len(d["bans"]))')"
check "a ban with nothing to match is refused" "2" "$(status run ban '{"reason": "x"}')"
check "unban by account id" "1" "$(run unban '{"beammp": "4242"}' | jq1 'print(len(d["bans"]))')"
check "unbanning nobody says so" "2" "$(status run unban '{"name": "ghost"}')"

# Backups and restore
check "a backup" "0" "$(status run backup manual force)"
name="$(run backups | jq1 'print(d["backups"][0]["name"])')"
check "the backup holds the config and plugins, not the client mods" "yes no" "$(tar -tzf "${data}/flux/backups/${name}" | grep -q 'Resources/Server/Loose' && echo yes) $(tar -tzf "${data}/flux/backups/${name}" | grep -q 'Resources/Client' && echo yes || echo no)"
rm -rf "${data}/Resources/Server/Loose"
check "a restore is accepted" "0" "$(status run restore "${name}")"
check "and applied before the next start" "True" "$(run apply-restore | jq1 'print(bool(d["safetyBackup"]))')"
check "the plugin is back" "0" "$(status test -f "${data}/Resources/Server/Loose/main.lua")"
check "a name that is not a backup is refused" "2" "$(status run restore '../x')"

# Status with no server
check "status with no server" "stopped False" "$(run status | jq1 'print(d["state"], d["online"])')"

# --- The entrypoint: server-binary warnings never reach the answer -------------------------------
# The real capture line of start_generation, run with a beammp that warns on stderr. A process
# substitution inside $(...) would write the logged warning into the answer.
# shellcheck disable=SC2016
block="$(sed -n '/^  answer="\$(beammp server-binary/,/flux-server-binary.err$/p' scripts/flux-entrypoint.sh)"
# shellcheck disable=SC2329
(
  beammp() { echo '{"path": "/x/BeamMP-Server"}'; echo "binary warning: slow" >&2; }
  flux_log() { echo "LOG $*" >>"${tmp}/entry.log"; echo "$*"; }
  answer=""
  eval "${block}"
  printf '%s' "${answer}" >"${tmp}/answer.out"
) >/dev/null
check "the warning is still logged" "LOG server: binary warning: slow" "$(cat "${tmp}/entry.log")"
check "server-binary warnings stay out of the answer" '{"path": "/x/BeamMP-Server"}' "$(cat "${tmp}/answer.out")"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
