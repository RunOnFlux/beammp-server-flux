# BeamMP (BeamNG.drive multiplayer) server image for Flux.
#
# Written from scratch. BeamMP's own native Linux server (github.com/BeamMP/BeamMP-Server, AGPL-3.0,
# shipped unmodified), under a supervisor that writes ServerConfig.toml from the panel's settings and
# the deploy's env, keeps the server on the newest stable release, gives the hub a console, a player
# list, bans (the built-in FluxAdmin Lua plugin), mods, plugins and backups, stops it cleanly and
# restarts it in place. See README.md.
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev
# The build the image ships, used when GitHub cannot be reached; the supervisor downloads newer
# stable releases itself (BEAMMP_VERSION=latest).
ARG BEAMMP_SERVER_VERSION=3.9.3

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates curl procps tzdata python3 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/beammp && \
    curl -fsSL --retry 5 -o /opt/beammp/BeamMP-Server \
      "https://github.com/BeamMP/BeamMP-Server/releases/download/v${BEAMMP_SERVER_VERSION}/BeamMP-Server.ubuntu.24.04.x86_64" && \
    chmod 0755 /opt/beammp/BeamMP-Server && \
    /opt/beammp/BeamMP-Server --version | grep -q "v${BEAMMP_SERVER_VERSION}" && \
    printf '%s\n' "${BEAMMP_SERVER_VERSION}" >/opt/beammp/VERSION

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-console.sh scripts/fluxbeammp.py /opt/flux/
COPY lua/FluxAdmin /opt/flux/FluxAdmin
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-console.sh /usr/local/bin/flux-console && \
    ln -s /opt/flux/fluxbeammp.py /usr/local/bin/flux-beammp

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/beammp/data", "/mnt/beammp/server"]

# One port, TCP and UDP: players connect on TCP, vehicles sync over UDP.
EXPOSE 30814/tcp 30814/udp

# Healthy while the supervisor runs: with no AuthKey there is deliberately no server process, and
# a container that restarts for it would not get a key.
HEALTHCHECK --interval=60s --timeout=10s --start-period=5m --retries=3 \
    CMD pgrep -f flux-entrypoint.sh >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
