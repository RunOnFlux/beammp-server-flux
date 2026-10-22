# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**: the BeamMP (BeamNG.drive multiplayer) server for Flux,
`runonflux/beammp-server-flux`. ubuntu:24.04, BeamMP's native Linux server from its GitHub releases
(unmodified, AGPL-3.0), and a supervisor in bash. Same family as `~/work/tf2-server-flux` and
`~/work/dst-server-flux`; read them for the patterns this one follows.

The rule that shapes everything: **the container supervises its own server.** PID 1 is
`flux-entrypoint.sh`, never the server. The server runs as a child so a stop becomes a clean `exit`,
and a server that ends on its own is followed by the next one in place.

## Commands

```bash
./tests/test-flux.sh
docker build -t beammp-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A change to what the image does bumps `VERSION` and gets a line under "Versions" in the README.

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: the server build, a restore, FluxAdmin put
  back, a backup, `flux-beammp apply` (ServerConfig.toml), the server, then the backupper and the
  updater.
- `scripts/fluxbeammp.py` (`flux-beammp`): every decision about the files (settings, the TOML, mods,
  plugins, bans, backups, versions) and the hub's commands. The one place those rules live.
- `lua/FluxAdmin/main.lua`: the server plugin the image installs: `flux players` / `flux kick` on the
  console, bans on join.
- `scripts/flux-lib.sh`: shared helpers. **Sourcing it must stay side-effect free**: the tests
  source it directly.

## Things that will bite you

- **No AuthKey, no server**: BeamMP exits 1 after 10 s. The supervisor does not start it and waits
  (state `needs-key`); a crash loop would only end the container with 42.
- **BeamMP reads BEAMMP_* from its environment OVER the config file.** The server is started with
  `env -i`; never pass the deploy's env through.
- **The server does not exit after "Shutdown." while its stdin is open.** The supervisor closes its
  end of the console FIFO when it sees that line. NO child may inherit fd 3: the server subshell
  closes it before the log pipe is made (a process substitution created while bash juggles fd 3
  gets a copy as fd 10, measured), the background helpers start with `3>&-`.
- **Plugins read `ServerConfig.toml` and `Resources/...` relative to the working directory**
  (CobaltEssentials, Nickel). `run/` has links to both; `ResourceFolder` stays `"Resources"`.
- **Settings precedence**: `flux/settings.json` is the truth; a `BEAMMP_*` env value is applied to it
  only when it differs from the one recorded in `flux/env-applied.json`. A restore re-seeds that
  record, or the next start would undo the restore.
- **`protectmod` leaves mods.json with trailing garbage**; `mods_db()` cleans it.
- **Every .zip in Resources/Client goes to every player.** A mod that is off lives in
  `flux/mods-disabled`; a non-zip there only draws a warning.
- **Lua's JSON encodes an empty table as `{}`**: FluxAdmin spells out an empty player list.
- **Flux stops a container with Docker's default 10 seconds.** Measured stop: 2.5 s.
- **Mod downloads run detached** (`mod-install-url` starts `mod-download <id>` in its own session, no inherited fds): an appexec cannot last as long as a map pack takes. The job file and the partial file live in `$FLUX_SERVER_DIR/downloads` (local); only the finished `.zip` reaches the data volume. BeamNG.com's `/download` without `?version=` answers 403, so a repository page is read for its newest version's link.
- **`flux.log` is local** (`$FLUX_SERVER_DIR/flux-logs/flux.log`, 5 MB then one `.1`), never on the synced data volume: a constantly written file there is constant Syncthing traffic. `flux_log_migrate` moves an old one off the data volume at start. `flux_banner` prints the FluxCloud banner at container start and every generation; its text is tested.
- **The scheduled CI run publishes only with something to apply** (`.github/ci/needs-rebuild.sh`): urgent security updates, or commits on main since the published `:latest` (label `org.opencontainers.image.revision`) that touch the image inputs.
