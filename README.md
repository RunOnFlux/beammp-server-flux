# beammp-server-flux

The [BeamMP](https://beammp.com) (BeamNG.drive multiplayer) server for [Flux](https://runonflux.io),
as `runonflux/beammp-server-flux`. BeamMP's own native Linux server
([BeamMP/BeamMP-Server](https://github.com/BeamMP/BeamMP-Server), AGPL-3.0, run unmodified), under a
supervisor that:

- writes `ServerConfig.toml` before every start from the panel's settings (`flux/settings.json`) and
  the deploy's env; a deploy value lands when it **changed** since the last start, so a change made
  in the panel is not undone by the next restart
- keeps the server on the **newest stable BeamMP release** (`BEAMMP_VERSION=latest`, GitHub's
  releases API, cached 6 h); downloaded into the local volume and checked with `--version`; the
  build in the image (3.9.3) when GitHub cannot be reached. A newer release restarts the server onto
  it, but only while nobody is playing
- **waits instead of crash-looping without an AuthKey** (BeamMP exits after 10 s without one) and
  says in the log where to get one
- runs the server with a **clean environment** (BeamMP reads `BEAMMP_*` over its config file, which
  would make the panel's settings unchangeable)
- gives the hub a console (`flux-console`), the built-in **FluxAdmin** Lua plugin (a JSON player list,
  kick by id, bans enforced on join), mods and plugins management, backups (`flux-beammp`)
- stops cleanly (`exit` on the console, players kicked, ~2.5 s) and restarts the server in place

## Volumes

| Path | Flux mount | What |
|---|---|---|
| `/mnt/beammp/data` | `g:` (synced) | `ServerConfig.toml` (generated), `Resources/Client/*.zip` (mods players download), `Resources/Server/<plugin>/` (Lua plugins and their data), `flux/` (settings, bans, disabled mods and plugins, backups, our log) |
| `/mnt/beammp/server` | `ml:server` (local) | the BeamMP-Server builds downloaded from GitHub, `run/` (the working directory: `ServerConfig.toml` and `Resources` there are links to the data volume, because plugins read them relative to it), the console logs (`logs/`, 10 MB each, the newest 5) |

Spec: `g:/mnt/beammp/data|ml:server:/mnt/beammp/server`.

## Port

`GAME_PORT` (30814): players connect over TCP, vehicles sync over UDP, on the same number. The
server tells the BeamMP backend this port, so a remapped port must also be the one it binds.

## Environment

| Variable | Setting | |
|---|---|---|
| `BEAMMP_AUTH_KEY` | `AuthKey` | **Required.** Free at [keymaster.beammp.com](https://keymaster.beammp.com) (Discord login, Keys, +). One key runs one server at a time |
| `BEAMMP_NAME` | `Name` | the name in the server list (BeamNG formatting codes like `^l` work) |
| `BEAMMP_DESCRIPTION` | `Description` | |
| `BEAMMP_TAGS` | `Tags` | comma separated (`Freeroam,Racing`) |
| `BEAMMP_MAP` | `Map` | `/levels/<folder>/info.json`, or just the folder (`italy`) |
| `BEAMMP_MAX_PLAYERS` | `MaxPlayers` | held to `FLUX_MAX_PLAYERS_CAP` when that is set (the plan's figure) |
| `BEAMMP_MAX_CARS` | `MaxCars` | cars per player |
| `BEAMMP_PRIVATE` | `Private` | `true` = not in the server list (direct connect only) |
| `BEAMMP_ALLOW_GUESTS` | `AllowGuests` | players without a BeamMP account |
| `BEAMMP_LOG_CHAT` | `LogChat` | |
| `BEAMMP_VERSION` | | `latest` (default) or a pinned version (`3.9.3`) |

Supervisor knobs: `FLUX_BACKUP_HOURS` (6), `FLUX_BACKUP_KEEP` (10), `FLUX_UPDATE_CHECK_HOURS` (6),
`FLUX_RESTART_MAX_ATTEMPTS` (5) in `FLUX_RESTART_WINDOW` (3600 s), then exit 42.

## For the hub

`flux-console <command>`: one console command, its answer printed (`list`, `status`, `say <text>`,
`kick <name>`, `reloadmods`, `protectmod`, `version`, and FluxAdmin's `flux players` /
`flux kick <id> <reason>`, which answer one `FLUXJSON {...}` line).

`flux-beammp` (JSON):

| Command | |
|---|---|
| `status` | the supervisor's state (`running`, `needs-key`, `starting`), the AuthKey as the backend answered (`ok`, `refused` + reason, `missing`, `invalid`, `private`), the version and the newest release, the server's information packet (players, map, mods) |
| `files` | settings, mods (on/off, protected, the maps inside), plugins, stock and modded maps, bans |
| `set-map <path>` | refused unless a stock map or an enabled mod has it |
| `mod-install <file>` / `mod-enable <file> on\|off` / `mod-protect <file> on\|off` / `mod-remove <file>` | `.zip` into `Resources/Client`; off = `flux/mods-disabled` |
| `plugin-install <zip>` / `plugin-install-url <github release zip>` / `plugin-enable <name> on\|off` / `plugin-remove <name>` | any of the four ways plugins ship (a Resources folder, Server/Client, a plugin folder, loose files); an update keeps the files the plugin wrote |
| `ban '{"name","beammp","ip","reason"}'` / `unban '{...}'` | `flux/bans.json`, read by FluxAdmin on every join |
| `backups` / `restore <backup>` / `restart [why]` | |

`/tmp/flux-generation` holds `<generation> <epoch>`: a restart is over when it changes.

## Measured (BeamMP-Server 3.9.3, 2026-10-18)

- Image 137 MB. The server binary is 12 MB; nothing else is downloaded.
- Idle: **13-25 MB RAM**, ~1% of a core, with CobaltEssentials and Nickel loaded 24 MB.
- From start to listening: under a second; a restart from the panel ~8 s (5 s of it the backoff).
- `docker stop`: 2.5 s, exit 0.
- An invalid key on a public server: it runs and answers, the log says "Backend REFUSED the auth
  key", and `status` shows Heartbeat and Main stuck in "Starting" (measured). The source
  (TNetwork.cpp) turns every joining player away while Main is starting ("The server is still
  starting"). A private server with the same key reaches "ALL SYSTEMS STARTED" (measured); whether
  players can then join is not verified (player logins are checked against the backend with the key).
- `protectmod` leaves `mods.json` with a tail of the previous document; `flux-beammp` cleans it.

## Versions

- 1.0.0: first release.

## Licence

The scripts in this repository are the Flux team's. BeamMP-Server is © BeamMP Ltd. and contributors,
AGPL-3.0, downloaded unmodified from its GitHub releases.
