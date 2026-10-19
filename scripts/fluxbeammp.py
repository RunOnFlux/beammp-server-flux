#!/usr/bin/env python3
"""Every decision about the BeamMP server's files, and the hub's commands. Each prints one JSON document.

For the hub (flux-beammp ...):
    status                         what the supervisor is doing, the AuthKey's state, the version, and
                                   the server's own information packet (name, map, players)
    files                          the panel's settings, the client mods (on, off, protected, the maps in
                                   them), the server plugins, the maps a server can start on, the bans
    set-map <path>                 /levels/<name>/info.json into the settings (applied on the next start)
    mod-install <file>             a .zip into Resources/Client (checked: a ZIP archive)
    mod-enable <file> on|off       off = moved out to flux/mods-disabled (the server sends every .zip in
                                   Resources/Client to every player)
    mod-protect <file> on|off      a protected mod is not sent: players must already have it
    mod-remove <file>
    plugin-install <file>          a .zip of a server plugin (or a plugin + its client mod), laid out the
                                   way plugins ship: see install_plugin_tree
    plugin-install-url <url>       the same, downloaded from a GitHub release (github.com only)
    plugin-enable <name> on|off    off = moved out to flux/plugins-disabled
    plugin-remove <name>
    plugins-apply                  with a server running, the plugin changes above are QUEUED (BeamMP aborts
                                   when a plugin folder changes under it): this restarts the server, and
                                   the supervisor applies them between the two servers
    plugins-discard                drops the queued changes
    ban '<json>'                   {"name", "beammp", "ip", "reason"} into flux/bans.json (FluxAdmin
                                   refuses them on join)
    unban '<json>'                 {"beammp"} or {"name"} or {"ip"}: every matching ban is lifted
    backups                        the backups in flux/backups
    restore <backup>               the server stops, a safety backup is taken, the backup is put back,
                                   the server starts again (the supervisor does it)
    restart [why]                  the server stops and the supervisor starts it again (settings, map)

For the supervisor:
    apply                          env -> settings (only values that CHANGED since the last start) ->
                                   ServerConfig.toml. Prints {"ok", "authKey": "ok|missing|invalid"}
    server-binary                  the BeamMP-Server to run: BEAMMP_VERSION (latest = the newest stable
                                   GitHub release), downloaded into the server volume, or the build the
                                   image ships when GitHub cannot be reached
    update-available               {"current", "latest", "update": bool}
    backup <why> [force]
    apply-restore
    apply-plugin-ops               the queued plugin changes, before the server starts

Names are file names, never paths: anything that would leave its folder is refused.
"""

import calendar
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile

DATA = os.environ.get("FLUX_DATA_DIR", "/mnt/beammp/data")
SERVER = os.environ.get("FLUX_SERVER_DIR", "/mnt/beammp/server")
RESOURCES = os.path.join(DATA, "Resources")
CLIENT = os.path.join(RESOURCES, "Client")
PLUGINS = os.path.join(RESOURCES, "Server")
STATE_DIR = os.path.join(DATA, "flux")
MODS_OFF = os.path.join(STATE_DIR, "mods-disabled")
PLUGINS_OFF = os.path.join(STATE_DIR, "plugins-disabled")
PLUGINS_PENDING = os.path.join(STATE_DIR, "plugins-pending")
PLUGIN_OPS = os.path.join(STATE_DIR, "plugin-ops.json")
SETTINGS = os.path.join(STATE_DIR, "settings.json")
ENV_APPLIED = os.path.join(STATE_DIR, "env-applied.json")
BANS = os.path.join(STATE_DIR, "bans.json")
CONFIG = os.path.join(DATA, "ServerConfig.toml")
BACKUPS = os.path.join(STATE_DIR, "backups")
BACKUP_REASONS = os.path.join(BACKUPS, "reasons.json")
RESTORE_REQUEST = os.path.join(STATE_DIR, "restore-request")
BIN_DIR = os.path.join(SERVER, "bin")
BUNDLED = os.environ.get("FLUX_BUNDLED_SERVER", "/opt/beammp/BeamMP-Server")
LATEST_CACHE = os.path.join(SERVER, "latest-release.json")
RESTART_MARKER = os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested")
GENERATION_FILE = os.environ.get("FLUX_GENERATION_FILE", "/tmp/flux-generation")
STATE_FILE = os.environ.get("FLUX_STATE_FILE", "/tmp/flux-state")
GAME_LOG_DIR = os.environ.get("FLUX_GAME_LOG_DIR", os.path.join(SERVER, "logs"))
BUILTIN_PLUGINS = {"FluxAdmin"}
RELEASES_API = os.environ.get("FLUX_RELEASES_API", "https://api.github.com/repos/BeamMP/BeamMP-Server/releases")
ASSET = os.environ.get("FLUX_SERVER_ASSET", "BeamMP-Server.ubuntu.24.04.x86_64")

# What a backup holds: the config, the panel's settings and bans, and the server plugins with the
# data they keep in their folders (CobaltEssentials' permissions, a race plugin's records). NOT the
# client mods: they are often gigabytes, are the owner's own uploads, and are synced to every
# standby node already. Their names are listed in the backup (flux/mods-list.json) so a restore
# can say what is missing.
BACKUP_ITEMS = ["ServerConfig.toml", "Resources/Server", "flux/settings.json", "flux/bans.json", "flux/plugins-disabled", "flux/mods-list.json"]
BACKUP_NAME = re.compile(r"^\d{8}-\d{6}-beammp\.tar\.gz$")

# The maps every BeamNG.drive install has (folder names under levels/), as Map takes them. The 14
# BeamMP's docs list (docs.beammp.com/server/server-maintenance) plus Cliff, which public servers
# run with no mod installed (backend.beammp.com/servers-info, 2026-10-18).
STOCK_MAPS = [
    ("gridmap_v2", "Gridmap V2"), ("west_coast_usa", "West Coast, USA"), ("east_coast_usa", "East Coast, USA"),
    ("italy", "Italy"), ("utah", "Utah, USA"), ("johnson_valley", "Johnson Valley"),
    ("jungle_rock_island", "Jungle Rock Island"), ("hirochi_raceway", "Hirochi Raceway"),
    ("automation_test_track", "Automation Test Track"), ("industrial", "Industrial Site"), ("derby", "Derby Arenas"),
    ("small_island", "Small Island, USA"), ("driver_training", "Driver Training"), ("smallgrid", "Grid, Small, Pure"),
    ("cliff", "Cliff"),
]

# The panel's settings: ServerConfig.toml's [General] keys the owner may change, with their defaults.
# AuthKey, Port, IP and ResourceFolder are the image's (env and the volume layout), never here.
DEFAULTS = {
    "Name": "BeamMP Server on Flux",
    "Description": "",
    "Tags": "Freeroam",
    "Map": "/levels/gridmap_v2/info.json",
    "MaxPlayers": 8,
    "MaxCars": 1,
    "Private": False,
    "AllowGuests": True,
    "LogChat": True,
    "InformationPacket": True,
    "Debug": False,
}
# The deploy's env for each setting: the server's own BEAMMP_* names (docs.beammp.com). The image
# does NOT hand them to the server (it would let them override the file forever); it applies a value
# to the settings when it CHANGED since the last start, so a change in Server Settings sticks and a
# change in Deployment Settings still lands.
ENV_KEYS = {
    "BEAMMP_NAME": "Name", "BEAMMP_DESCRIPTION": "Description", "BEAMMP_TAGS": "Tags", "BEAMMP_MAP": "Map",
    "BEAMMP_MAX_PLAYERS": "MaxPlayers", "BEAMMP_MAX_CARS": "MaxCars", "BEAMMP_PRIVATE": "Private",
    "BEAMMP_ALLOW_GUESTS": "AllowGuests", "BEAMMP_LOG_CHAT": "LogChat",
}
MAP_RE = re.compile(r"^/levels/([A-Za-z0-9_.\- ]{1,80})/info\.json$")
AUTH_KEY_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
MOD_NAME = re.compile(r"^[A-Za-z0-9_.+()\- ]{1,120}\.zip$")
PLUGIN_NAME = re.compile(r"^[A-Za-z0-9_.\- ]{1,64}$")
# Bigger than anything a player should be asked to download on join; the hub's own upload cap is lower.
MAX_UPLOAD_BYTES = 4 * 1024 ** 3
# A plugin archive that unpacks past this is refused (a zip bomb, or a modpack in the wrong tab).
MAX_PLUGIN_BYTES = 512 * 1024 ** 2


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=2):
    out({"ok": False, "error": message})
    sys.exit(code)


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".flux-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def read_json(path, default):
    text = read(path)
    if text is None:
        return default
    try:
        value = json.loads(text)
    except ValueError:
        return default
    return value if isinstance(value, type(default)) else default


def env(name):
    """An env value, or None: the marketplace writes a blank declared parameter as NAME=."""
    v = os.environ.get(name)
    return v if v is not None and v.strip() != "" else None


def generation():
    parts = (read(GENERATION_FILE) or "").split()
    return {"n": int(parts[0]), "since": int(parts[1])} if len(parts) == 2 and all(p.isdigit() for p in parts) else None


# ------------------------------------------------------------------------------------------------
# Settings -> ServerConfig.toml
# ------------------------------------------------------------------------------------------------

def norm_map(value):
    """A Map value as the server takes it: /levels/<folder>/info.json. A bare folder name or a path
    without the leading slash (both seen on public servers) is completed. None when it cannot be one."""
    v = str(value or "").strip()
    if re.fullmatch(r"[A-Za-z0-9_.\- ]{1,80}", v):
        v = f"/levels/{v}/info.json"
    if v.startswith("levels/"):
        v = "/" + v
    m = MAP_RE.match(v)
    # A folder of dots only is a path, not a map.
    return v if m and m.group(1).strip(".") else None


def to_bool(value):
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def coerce(key, value):
    """A setting's value in its type, or None when it is not one."""
    default = DEFAULTS[key]
    if isinstance(default, bool):
        return to_bool(value)
    if isinstance(default, int):
        try:
            n = int(str(value).strip())
        except ValueError:
            return None
        return n if 1 <= n <= 1000 else None
    if key == "Map":
        return norm_map(value)
    text = re.sub(r"[\x00-\x1f\x7f]", "", str(value))
    return text[:500] if key == "Description" else text[:120]


def player_cap():
    try:
        cap = int(env("FLUX_MAX_PLAYERS_CAP") or 0)
    except ValueError:
        cap = 0
    return cap if cap > 0 else None


def effective_settings(stored, cap=None):
    """The settings the server runs with: the stored ones over the defaults, each checked, and
    MaxPlayers held to the plan's cap. Returns (settings, notes)."""
    s, notes = dict(DEFAULTS), []
    for key, value in (stored or {}).items():
        if key not in DEFAULTS:
            continue
        v = coerce(key, value)
        if v is None:
            notes.append(f"{key} '{value}' is not valid; using {DEFAULTS[key]!r}")
            continue
        s[key] = v
    if cap and s["MaxPlayers"] > cap:
        notes.append(f"MaxPlayers {s['MaxPlayers']} is over this plan's {cap}; using {cap}")
        s["MaxPlayers"] = cap
    return s, notes


def merge_env(stored, applied, environ):
    """The settings after the deploy's env: a BEAMMP_* value that differs from the one applied at the
    last start is written over the stored setting (it was changed in Deployment Settings); one that
    did not change leaves the setting alone (it may have been changed in Server Settings since).
    Returns (settings, applied)."""
    stored, applied = dict(stored or {}), dict(applied or {})
    for name, key in ENV_KEYS.items():
        value = environ.get(name)
        if value is None or value.strip() == "":
            continue
        if applied.get(name) == value:
            continue
        v = coerce(key, value)
        if v is not None:
            stored[key] = v
        applied[name] = value
    return stored, applied


def toml_string(value):
    s = str(value)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    s = re.sub(r"[\x00-\x1f\x7f]", lambda m: "\\u%04x" % ord(m.group(0)), s)
    return f'"{s}"'


def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return toml_string(value)


def render_config(settings, auth_key, port):
    """ServerConfig.toml. The server rewrites it at every start in its own layout (measured), so it
    is regenerated from the panel's settings before every start: never edit it by hand."""
    general = {
        "Name": settings["Name"], "Description": settings["Description"], "Tags": settings["Tags"],
        "Map": settings["Map"], "MaxPlayers": settings["MaxPlayers"], "MaxCars": settings["MaxCars"],
        "Private": settings["Private"], "AllowGuests": settings["AllowGuests"], "LogChat": settings["LogChat"],
        "InformationPacket": settings["InformationPacket"], "Debug": settings["Debug"],
        "AuthKey": auth_key or "", "Port": int(port), "IP": "::",
        # Relative, as plugins expect: the server runs in <server>/run, where Resources and
        # ServerConfig.toml are links to the data volume (flux-entrypoint.sh).
        "ResourceFolder": "Resources",
    }
    lines = [
        "# Written by runonflux/beammp-server-flux before every start, from the Flux panel's settings",
        "# (flux/settings.json) and the deploy's AuthKey. Changes made here are lost: use the panel.",
        "[General]",
    ] + [f"{k} = {toml_value(v)}" for k, v in general.items()] + [
        "", "[Misc]",
        # The image follows BeamMP's releases itself (BEAMMP_VERSION): the reminder is noise.
        "ImScaredOfUpdates = true", 'UpdateReminderTime = "30d"', "",
    ]
    return "\n".join(lines)


def cmd_apply():
    stored = read_json(SETTINGS, {})
    applied = read_json(ENV_APPLIED, {})
    first = not os.path.exists(SETTINGS)
    stored, applied = merge_env(stored, applied, os.environ)
    settings, notes = effective_settings(stored, player_cap())
    # The file keeps what the server actually runs with (a capped MaxPlayers shows as the cap).
    write_text(SETTINGS, json.dumps({k: settings[k] for k in DEFAULTS}, indent=2, ensure_ascii=False) + "\n")
    write_text(ENV_APPLIED, json.dumps(applied, indent=2) + "\n")
    key = (env("BEAMMP_AUTH_KEY") or "").strip()
    port = env("GAME_PORT") or env("BEAMMP_PORT") or "30814"
    write_text(CONFIG, render_config(settings, key, port))
    os.makedirs(CLIENT, exist_ok=True)
    os.makedirs(PLUGINS, exist_ok=True)
    mods_db()  # a mods.json BeamMP left with a tail is cleaned before the server reads it
    state = "ok" if AUTH_KEY_RE.match(key) else ("missing" if not key else "invalid")
    warnings = list(notes)
    if not map_available(settings["Map"]):
        warnings.append(f"the map {settings['Map']} is neither a stock map nor in an enabled mod: players cannot load it")
    out({"ok": True, "first": first, "authKey": state, "map": settings["Map"], "maxPlayers": settings["MaxPlayers"],
         "private": settings["Private"], "warnings": warnings})


# ------------------------------------------------------------------------------------------------
# Mods (Resources/Client) and the maps in them
# ------------------------------------------------------------------------------------------------

def mod_maps(path):
    """The maps a mod archive carries: levels/<folder>/info.json inside it."""
    try:
        with zipfile.ZipFile(path) as z:
            found = set()
            for n in z.namelist():
                m = re.match(r"^levels/([^/]+)/info\.json$", n, re.I)
                if m:
                    found.add(m.group(1))
            return sorted(found, key=str.lower)
    except (OSError, zipfile.BadZipFile):
        return []


def mods_db():
    """Resources/Client/mods.json, the server's own record of each mod's hash and `protected` flag.

    BEAMMP LEAVES IT BROKEN: `protectmod` rewrites the file without truncating it, so a shorter
    document keeps the old one's tail after it ("...}\n}", measured on 3.9.3), and the server's
    next read fails ("Failed to load mods.json") and forgets every protected flag. The first
    document is read, and the file is written back clean when it had a tail."""
    path = os.path.join(CLIENT, "mods.json")
    text = read(path)
    if not text or not text.strip():
        return {}
    try:
        value, end = json.JSONDecoder().raw_decode(text.lstrip())
    except ValueError:
        return {}
    if not isinstance(value, dict):
        return {}
    if text.lstrip()[end:].strip():
        write_text(path, json.dumps(value, indent=4))
    return value


def mod_rows():
    db = mods_db()
    rows = []
    for folder, enabled in ((CLIENT, True), (MODS_OFF, False)):
        try:
            names = sorted(os.listdir(folder), key=str.lower)
        except OSError:
            continue
        for n in names:
            p = os.path.join(folder, n)
            if not (os.path.isfile(p) and n.lower().endswith(".zip")):
                continue
            st = os.stat(p)
            entry = db.get(n) if isinstance(db.get(n), dict) else {}
            rows.append({"file": n, "size": st.st_size, "modified": int(st.st_mtime), "enabled": enabled,
                         "protected": bool(entry.get("protected")), "maps": mod_maps(p)})
    return rows


def map_available(path, mods=None):
    m = MAP_RE.match(path or "")
    if not m:
        return False
    folder = m.group(1).lower()
    if folder in {s for s, _ in STOCK_MAPS}:
        return True
    for row in (mods if mods is not None else mod_rows()):
        if row["enabled"] and folder in {x.lower() for x in row["maps"]}:
            return True
    return False


def safe_mod(name):
    name = os.path.basename(str(name or "").strip())
    if not MOD_NAME.match(name):
        fail(f"not an allowed mod file name (letters, digits, spaces, _ . + ( ) -, ending in .zip): {name or '(empty)'}")
    return name


def upload_name(src):
    """The hub uploads as <epoch ms>-<name>: the prefix goes."""
    return re.sub(r"^\d{10,}-", "", os.path.basename(src))


def check_zip(src):
    if not os.path.isfile(src):
        fail("the uploaded file is not there")
    if os.path.getsize(src) > MAX_UPLOAD_BYTES:
        fail("the file is over 4 GB")
    with open(src, "rb") as f:
        if f.read(4) != b"PK\x03\x04":
            fail("not a ZIP archive: BeamNG mods are .zip files")
    try:
        with zipfile.ZipFile(src) as z:
            z.infolist()
    except zipfile.BadZipFile:
        fail("the ZIP archive is damaged")


def cmd_mod_install(src):
    name = safe_mod(upload_name(src).replace("%20", " "))
    check_zip(src)
    os.makedirs(CLIENT, exist_ok=True)
    # A disabled copy of the same mod is replaced too: one file per name.
    try:
        os.remove(os.path.join(MODS_OFF, name))
    except OSError:
        pass
    dst = os.path.join(CLIENT, name)
    # Moved, not copied, when the upload is on the same volume (the hub uploads into flux/uploads):
    # a mod pack can be gigabytes, and a copy would need the space twice.
    try:
        os.replace(src, dst)
    except OSError:
        shutil.copyfile(src, dst + ".flux-part")
        os.replace(dst + ".flux-part", dst)
    reload_mods()
    out({"ok": True, "mod": name, "size": os.path.getsize(dst), "maps": mod_maps(dst)})


def move(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.lexists(dst):
        shutil.rmtree(dst) if os.path.isdir(dst) and not os.path.islink(dst) else os.remove(dst)
    os.replace(src, dst)


def cmd_mod_enable(name, on):
    name = safe_mod(name)
    on = to_bool(on)
    src, dst = (os.path.join(MODS_OFF, name), os.path.join(CLIENT, name)) if on else (os.path.join(CLIENT, name), os.path.join(MODS_OFF, name))
    if not os.path.exists(src):
        if os.path.exists(dst):
            out({"ok": True, "mod": name, "enabled": on})
            return
        fail("no such mod")
    move(src, dst)
    reload_mods()
    out({"ok": True, "mod": name, "enabled": on})


def cmd_mod_protect(name, on):
    """mods.json's `protected`: a protected mod is listed but not sent, so only players who own it
    (a paid mod) can join. The server reads mods.json when it (re)loads mods; with a server running,
    its own `protectmod` command makes the change live and writes the file itself."""
    name = safe_mod(name)
    on = to_bool(on)
    if not os.path.isfile(os.path.join(CLIENT, name)):
        fail("only an enabled mod can be protected")
    live = console(f"protectmod {name} {'true' if on else 'false'}")
    if live:
        time.sleep(0.5)
        mods_db()  # the server wrote the file: clean it
    else:
        db = mods_db()
        if isinstance(db.get(name), dict):
            db[name]["protected"] = on
            write_text(os.path.join(CLIENT, "mods.json"), json.dumps(db, indent=4))
        else:
            fail("the server has not read this mod yet: start the server once, then protect it")
    out({"ok": True, "mod": name, "protected": on, "live": live})


def cmd_mod_remove(name):
    name = safe_mod(name)
    removed = False
    for folder in (CLIENT, MODS_OFF):
        try:
            os.remove(os.path.join(folder, name))
            removed = True
        except OSError:
            pass
    if not removed:
        fail("no such mod")
    reload_mods()
    out({"ok": True, "mod": name})


def console(command):
    """One command into the running server's console; False when no server is running."""
    try:
        return subprocess.run(["flux-console", command], capture_output=True, text=True, timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def reload_mods():
    """`reloadmods`: the running server re-reads Resources/Client (players joining from now on get the
    new list; players already on keep what they downloaded)."""
    console("reloadmods")


# ------------------------------------------------------------------------------------------------
# Server plugins (Resources/Server/<name>/)
# ------------------------------------------------------------------------------------------------

def tree_size(path):
    total, files, lua = 0, 0, False
    for root, _dirs, names in os.walk(path):
        for n in names:
            try:
                total += os.path.getsize(os.path.join(root, n))
            except OSError:
                continue
            files += 1
            lua = lua or n.lower().endswith(".lua")
    return total, files, lua


def plugin_rows():
    rows = []
    for folder, enabled in ((PLUGINS, True), (PLUGINS_OFF, False)):
        try:
            names = sorted(os.listdir(folder), key=str.lower)
        except OSError:
            continue
        for n in names:
            p = os.path.join(folder, n)
            if not os.path.isdir(p):
                continue
            size, files, lua = tree_size(p)
            rows.append({"name": n, "enabled": enabled, "builtin": n in BUILTIN_PLUGINS, "size": size, "files": files, "hasLua": lua})
    return rows


def safe_plugin(name):
    name = os.path.basename(str(name or "").strip())
    if not PLUGIN_NAME.match(name) or name in (".", ".."):
        fail(f"not an allowed plugin name: {name or '(empty)'}")
    return name


def plugin_layout(names, prefix=""):
    """How a plugin archive is laid out, from its member names. Plugins ship in four shapes:

      Resources/Server/<P>/..., Resources/Client/*.zip   a whole Resources folder (BeamJoy, Nickel)
      Server/<P>/..., Client/*.zip                        the same without Resources/
      <P>/main.lua ...                                    plugin folders (CobaltEssentials' zip)
      main.lua, lib/...                                   the plugin's files loose (named after the zip)

    Returns (kind, prefix): kind is 'resources', 'folder' or 'loose'; prefix is stripped from every
    member name. A single top folder around a Resources/Server/Client layout (a GitHub source zip's
    <repo>-<tag>/) is looked through."""
    names = [n[len(prefix):] for n in names if n.startswith(prefix) and not n.startswith("__MACOSX/")]
    names = [n for n in names if n and not n.endswith("/")]
    tops = {n.split("/", 1)[0] for n in names}
    if "Resources" in tops:
        return "resources", prefix + "Resources/"
    if tops and tops <= {"Server", "Client"}:
        return "resources", prefix
    all_in_folders = all("/" in n for n in names)
    if len(tops) == 1 and all_in_folders:
        top = next(iter(tops))
        inner = {n.split("/", 2)[1] for n in names if n.count("/") >= 2}
        if inner & {"Resources", "Server", "Client"}:
            return plugin_layout([prefix + n for n in names], prefix + top + "/")
        return "folder", prefix
    if tops and all_in_folders:
        return "folder", prefix
    return "loose", prefix


def safe_members(z, prefix):
    """The archive's members under prefix, each a relative path that stays inside, sizes summed."""
    total, members = 0, []
    for info in z.infolist():
        name = info.filename.replace("\\", "/")
        if name.startswith("__MACOSX/") or not name.startswith(prefix):
            continue
        rel = name[len(prefix):]
        if not rel or rel.endswith("/"):
            continue
        parts = rel.split("/")
        if any(p in ("", "..") for p in parts) or rel.startswith("/") or ":" in parts[0]:
            fail(f"the archive holds a path that leaves its folder: {name}")
        total += info.file_size
        if total > MAX_PLUGIN_BYTES:
            fail("the archive unpacks to more than 512 MB: that is a modpack, not a plugin")
        members.append((info, rel))
    return members


def extract(z, members, dest):
    for info, rel in members:
        target = os.path.join(dest, *rel.split("/"))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with z.open(info) as src, open(target, "wb") as dst:
            shutil.copyfileobj(src, dst)


def carry_over(old, new):
    """Copies into `new` every file of `old` that `new` does not have: what a plugin wrote for itself
    (its settings, its database) survives an update of its code."""
    for root, _dirs, names in os.walk(old):
        rel = os.path.relpath(root, old)
        for n in names:
            target = os.path.normpath(os.path.join(new, rel, n))
            if not os.path.lexists(target):
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy2(os.path.join(root, n), target)


# PLUGIN FOLDERS ARE NEVER CHANGED UNDER A RUNNING SERVER. BeamMP's plugin monitor watches
# Resources/Server, and a folder that disappears while it runs aborts the server ("Assertion failed
# in 'InitializePlugin': fs::exists(Folder)", then a filesystem_error and exit 134, measured on 3.9.3).
# So with a server running, an install, a switch on or off and a removal are QUEUED in
# flux/plugin-ops.json (an install's files staged in flux/plugins-pending/), and `plugins-apply`
# restarts the server: the supervisor applies the queue between the two servers. With no server
# running they are applied at once.

def server_running():
    """The supervisor says it runs a server (its state file), and the process is there."""
    if (read(STATE_FILE) or "").strip() != "running":
        return False
    try:
        return subprocess.run(["pgrep", "-x", "BeamMP-Server"], capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def pending_ops():
    return [o for o in read_json(PLUGIN_OPS, []) if isinstance(o, dict) and o.get("op") in ("install", "enable", "remove")]


def queue_op(op):
    """Adds a change to the queue, applied in order. A second change of the same kind to the same
    plugin replaces the first (install + install, on + off); a removal drops everything queued for
    that plugin (and an install's staged files) before it."""
    if op["op"] == "remove":
        ops = [o for o in pending_ops() if o.get("name") != op["name"]]
        shutil.rmtree(os.path.join(PLUGINS_PENDING, op["name"]), ignore_errors=True)
    else:
        ops = [o for o in pending_ops() if not (o.get("name") == op["name"] and o.get("op") == op["op"])]
    ops.append(op)
    write_text(PLUGIN_OPS, json.dumps(ops, indent=2) + "\n")
    return ops


def do_install(name, staged):
    """The plugin folder `staged` becomes Resources/Server/<name>. An update replaces the code but
    keeps what the plugin wrote (settings, data): files in the old folder the new one lacks stay."""
    old = os.path.join(PLUGINS, name)
    off = os.path.join(PLUGINS_OFF, name)
    base = old if os.path.isdir(old) else (off if os.path.isdir(off) else None)
    if base:
        carry_over(base, staged)
        if base == off:
            shutil.rmtree(off)
    move(staged, os.path.join(PLUGINS, name))


def do_enable(name, on):
    src, dst = (os.path.join(PLUGINS_OFF, name), os.path.join(PLUGINS, name)) if on else (os.path.join(PLUGINS, name), os.path.join(PLUGINS_OFF, name))
    if os.path.isdir(src):
        move(src, dst)


def do_remove(name):
    for folder in (PLUGINS, PLUGINS_OFF):
        p = os.path.join(folder, name)
        if os.path.isdir(p):
            shutil.rmtree(p)


def install_plugin_tree(src, fallback_name):
    """Unpacks a plugin archive. Returns (plugins, mods, queued): the plugin folders installed (or
    queued, with a server running) and the client mods that came with them."""
    check_zip(src)
    installed, mods = [], []
    live = server_running()
    staging = tempfile.mkdtemp(dir=STATE_DIR, prefix="plugin-")
    try:
        with zipfile.ZipFile(src) as z:
            kind, prefix = plugin_layout([i.filename.replace("\\", "/") for i in z.infolist()])
            members = safe_members(z, prefix)
            if not members:
                fail("the archive is empty")
            if kind == "resources":
                server = [(i, r[len("Server/"):]) for i, r in members if r.startswith("Server/")]
                client = [(i, r[len("Client/"):]) for i, r in members if r.startswith("Client/") and "/" not in r[len("Client/"):]]
                if not server and not client:
                    fail("the archive has a Resources folder with nothing in Server/ or Client/")
                extract(z, server, os.path.join(staging, "Server"))
                extract(z, client, os.path.join(staging, "Client"))
            elif kind == "folder":
                extract(z, members, os.path.join(staging, "Server"))
            else:
                if not any(r.lower().endswith(".lua") for _, r in members):
                    fail("no .lua files in the archive: a server plugin is Lua. A .zip of cars or maps goes in the Mods tab.")
                extract(z, members, os.path.join(staging, "Server", fallback_name))
        server_dir = os.path.join(staging, "Server")
        names = [n for n in sorted(os.listdir(server_dir)) if os.path.isdir(os.path.join(server_dir, n))] if os.path.isdir(server_dir) else []
        for n in names:  # loose files beside the plugin folders are not a plugin
            name = safe_plugin(n)
            if name in BUILTIN_PLUGINS:
                fail(f"{name} is the image's own plugin and cannot be replaced")
        for n in names:
            if live:
                move(os.path.join(server_dir, n), os.path.join(PLUGINS_PENDING, n))
                queue_op({"op": "install", "name": n})
            else:
                do_install(n, os.path.join(server_dir, n))
            installed.append(n)
        client_dir = os.path.join(staging, "Client")
        for n in sorted(os.listdir(client_dir)) if os.path.isdir(client_dir) else []:
            if n.lower().endswith(".zip") and MOD_NAME.match(n):
                move(os.path.join(client_dir, n), os.path.join(CLIENT, n))
                mods.append(n)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    if not installed and not mods:
        fail("nothing to install: no plugin folder and no client mod in the archive")
    if mods:
        reload_mods()
    return installed, mods, live and bool(installed)


def cmd_plugin_install(src):
    base = re.sub(r"\.zip$", "", upload_name(src), flags=re.I)
    name = re.sub(r"[^A-Za-z0-9_.\-]", "_", base)[:64] or "Plugin"
    installed, mods, queued = install_plugin_tree(src, name)
    out({"ok": True, "plugins": installed, "mods": mods, "queued": queued})


GITHUB_URL = re.compile(r"^https://(github\.com/[\w.-]+/[\w.-]+/(releases/download/[^\s?#]+\.zip|archive/[^\s?#]+\.zip)|codeload\.github\.com/[\w.-]+/[\w.-]+/zip/[^\s?#]+)$")


def cmd_plugin_install_url(url):
    if not GITHUB_URL.match(url or ""):
        fail("only a .zip from a GitHub release (github.com/<owner>/<repo>/releases/download/...) can be installed by link")
    os.makedirs(STATE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, prefix="download-", suffix=".zip")
    os.close(fd)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "runonflux-beammp-server-flux"})
        with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
            total = 0
            while True:
                chunk = r.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_PLUGIN_BYTES:
                    fail("the download is over 512 MB")
                f.write(chunk)
        base = re.sub(r"\.zip$", "", url.rsplit("/", 1)[-1], flags=re.I)
        installed, mods, queued = install_plugin_tree(tmp, re.sub(r"[^A-Za-z0-9_.\-]", "_", base)[:64] or "Plugin")
    except OSError as e:
        fail(f"could not download it: {e}")
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    out({"ok": True, "plugins": installed, "mods": mods, "queued": queued})


def known_plugin(name):
    return os.path.isdir(os.path.join(PLUGINS, name)) or os.path.isdir(os.path.join(PLUGINS_OFF, name)) \
        or any(o["op"] == "install" and o["name"] == name for o in pending_ops())


def cmd_plugin_enable(name, on):
    name = safe_plugin(name)
    if name in BUILTIN_PLUGINS:
        fail(f"{name} is the image's own plugin (the panel's bans and player list): it stays on")
    on = to_bool(on)
    if not known_plugin(name):
        fail("no such plugin")
    if server_running():
        queue_op({"op": "enable", "name": name, "on": on})
        out({"ok": True, "plugin": name, "enabled": on, "queued": True})
        return
    do_enable(name, on)
    out({"ok": True, "plugin": name, "enabled": on, "queued": False})


def cmd_plugin_remove(name):
    name = safe_plugin(name)
    if name in BUILTIN_PLUGINS:
        fail(f"{name} is the image's own plugin: it cannot be removed")
    if not known_plugin(name):
        fail("no such plugin")
    if server_running():
        queue_op({"op": "remove", "name": name})
        out({"ok": True, "plugin": name, "queued": True})
        return
    do_remove(name)
    out({"ok": True, "plugin": name, "queued": False})


def cmd_apply_plugin_ops():
    """For the supervisor, between two servers: the queued plugin changes, in order."""
    done = []
    for o in pending_ops():
        name = os.path.basename(str(o.get("name") or ""))
        if not PLUGIN_NAME.match(name) or name in BUILTIN_PLUGINS:
            continue
        if o["op"] == "install":
            staged = os.path.join(PLUGINS_PENDING, name)
            if os.path.isdir(staged):
                do_install(name, staged)
                done.append(f"installed {name}")
        elif o["op"] == "enable":
            do_enable(name, bool(o.get("on")))
            done.append(f"{'on' if o.get('on') else 'off'} {name}")
        else:
            do_remove(name)
            done.append(f"removed {name}")
    try:
        os.remove(PLUGIN_OPS)
    except OSError:
        pass
    shutil.rmtree(PLUGINS_PENDING, ignore_errors=True)
    out({"ok": True, "applied": done})


def cmd_plugins_discard():
    """Drops the queued plugin changes (nothing on the server changes)."""
    try:
        os.remove(PLUGIN_OPS)
    except OSError:
        pass
    shutil.rmtree(PLUGINS_PENDING, ignore_errors=True)
    out({"ok": True})


def cmd_plugins_apply():
    """Applies the queued plugin changes: the server restarts (the supervisor applies them between
    the two servers), or, with none running, they are applied now."""
    if not pending_ops():
        out({"ok": True, "applied": [], "serverStopped": False})
        return
    if not server_running():
        cmd_apply_plugin_ops()
        return
    write_text(RESTART_MARKER, "requested: plugin changes\n")
    sent = console("exit")
    out({"ok": True, "serverStopped": sent})


# ------------------------------------------------------------------------------------------------
# Bans (enforced by the FluxAdmin plugin on join)
# ------------------------------------------------------------------------------------------------

def parse_obj(raw):
    try:
        value = json.loads(raw)
    except ValueError:
        fail("not JSON")
    if not isinstance(value, dict):
        fail("an object")
    return value


def clean(value, limit=80):
    return re.sub(r"[\x00-\x1f\x7f\"]", "", str(value or "")).strip()[:limit]


def cmd_ban(raw):
    b = parse_obj(raw)
    ban = {"name": clean(b.get("name"), 64), "beammp": clean(b.get("beammp"), 20), "ip": clean(b.get("ip"), 45),
           "reason": clean(b.get("reason"), 120), "at": int(time.time())}
    if ban["beammp"] and not ban["beammp"].isdigit():
        fail("a BeamMP account id is a number")
    if ban["ip"] and not re.fullmatch(r"[0-9a-fA-F:.]{3,45}", ban["ip"]):
        fail("not an IP address")
    if not (ban["name"] or ban["beammp"] or ban["ip"]):
        fail("a ban needs a player name, a BeamMP account id or an IP")
    bans = read_json(BANS, [])
    key = ("beammp", ban["beammp"]) if ban["beammp"] else (("name", ban["name"].lower()) if ban["name"] else ("ip", ban["ip"]))
    bans = [x for x in bans if not (isinstance(x, dict) and str(x.get(key[0]) or "").lower() == key[1])]
    bans.append({k: v for k, v in ban.items() if v != ""})
    write_text(BANS, json.dumps(bans, indent=2, ensure_ascii=False) + "\n")
    out({"ok": True, "bans": bans})


def cmd_unban(raw):
    b = parse_obj(raw)
    bans = read_json(BANS, [])
    keep = []
    for x in bans:
        if not isinstance(x, dict):
            continue
        hit = (b.get("beammp") and str(x.get("beammp") or "") == str(b["beammp"])) \
            or (b.get("name") and str(x.get("name") or "").lower() == str(b["name"]).lower() and not (b.get("beammp") and x.get("beammp"))) \
            or (b.get("ip") and str(x.get("ip") or "") == str(b["ip"]))
        if not hit:
            keep.append(x)
    if len(keep) == len(bans):
        fail("no such ban")
    write_text(BANS, json.dumps(keep, indent=2, ensure_ascii=False) + "\n")
    out({"ok": True, "bans": keep})


# ------------------------------------------------------------------------------------------------
# Status: the supervisor's state, the AuthKey as the backend answered it, the information packet
# ------------------------------------------------------------------------------------------------

def info_packet(port, host="127.0.0.1", timeout=3.0):
    """The server's information packet ('I' on its TCP port: an int32 length, then the same JSON it
    sends the server list): name, map, players, playerslist, mods. None when nothing answers."""
    try:
        with socket.create_connection((host, int(port)), timeout=timeout) as s:
            s.sendall(b"I")
            head = b""
            while len(head) < 4:
                chunk = s.recv(4 - len(head))
                if not chunk:
                    return None
                head += chunk
            n = struct.unpack("<i", head)[0]
            if n <= 0 or n > 1024 * 1024:
                return {} if n == 0 else None
            data = b""
            while len(data) < n:
                chunk = s.recv(n - len(data))
                if not chunk:
                    break
                data += chunk
        return json.loads(data.decode("utf-8", "replace"))
    except (OSError, ValueError, struct.error):
        return None


def current_log_lines(limit_bytes=2_000_000):
    """The current generation's console log (the newest file), its last couple of megabytes."""
    try:
        logs = sorted((os.path.join(GAME_LOG_DIR, n) for n in os.listdir(GAME_LOG_DIR) if n.endswith("-console.log")), key=os.path.getmtime)
    except OSError:
        return []
    if not logs:
        return []
    with open(logs[-1], "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - limit_bytes))
        return f.read().decode("utf-8", "replace").splitlines()


def auth_state(lines, private):
    """What the backend said about the AuthKey in this generation's log. A private server is not
    checked (the server sends the key but does not report the answer), so it reads 'private'."""
    state, reason = "unknown", None
    for line in lines:
        if "Authenticated!" in line or "Resumed authenticated session!" in line:
            state, reason = "ok", None
        elif "Backend REFUSED the auth key" in line:
            state = "refused"
            m = re.search(r"Reason: (.*)$", line)
            reason = m.group(1).strip() if m else None
        elif "No AuthKey specified" in line:
            state, reason = "missing", None
    if state == "unknown" and private:
        state = "private"
    return state, reason


def installed_version():
    text = read(os.path.join(SERVER, "current-version")) or ""
    return text.strip() or None


def cmd_status():
    settings, _ = effective_settings(read_json(SETTINGS, {}), player_cap())
    port = env("GAME_PORT") or env("BEAMMP_PORT") or "30814"
    state = (read(STATE_FILE) or "").strip() or "stopped"
    info = info_packet(port) if state == "running" else None
    auth, reason = auth_state(current_log_lines(), settings["Private"])
    if state == "needs-key":
        key = (env("BEAMMP_AUTH_KEY") or "").strip()
        auth = "missing" if not key else "invalid"
    latest = read_json(LATEST_CACHE, {}).get("version")
    players = [p for p in str((info or {}).get("playerslist") or "").split(";") if p]
    out({
        "generation": generation(), "state": state, "version": installed_version(), "latest": latest,
        "auth": auth, "authReason": reason, "private": settings["Private"], "port": int(port),
        "name": settings["Name"], "map": settings["Map"], "mapAvailable": map_available(settings["Map"]),
        "maxPlayers": settings["MaxPlayers"], "maxCars": settings["MaxCars"],
        "online": info is not None, "players": len(players) if info is not None else None, "playerNames": players,
        "mods": int((info or {}).get("modstotal") or 0) if info else None,
        "modsSize": int((info or {}).get("modstotalsize") or 0) if info else None,
        "clientVersion": (info or {}).get("clientversion"),
    })


def cmd_files():
    mods = mod_rows()
    settings, notes = effective_settings(read_json(SETTINGS, {}), player_cap())
    modded = []
    for row in mods:
        for folder in row["maps"]:
            modded.append({"path": f"/levels/{folder}/info.json", "folder": folder, "mod": row["file"], "enabled": row["enabled"]})
    out({
        "generation": generation(),
        "settings": settings, "notes": notes, "cap": player_cap(),
        "mods": mods,
        "modsSize": sum(r["size"] for r in mods if r["enabled"]),
        "plugins": plugin_rows(),
        # Plugin changes waiting for a restart (made while the server ran): see server_running.
        "pendingPlugins": pending_ops(),
        "maps": {"stock": [{"path": f"/levels/{f}/info.json", "folder": f, "name": n} for f, n in STOCK_MAPS], "modded": modded},
        "mapAvailable": map_available(settings["Map"], mods),
        "bans": read_json(BANS, []),
    })


def cmd_set_map(value):
    path = norm_map(value)
    if not path:
        fail("a map is /levels/<folder>/info.json (or just the folder name)")
    if not map_available(path):
        fail(f"{path} is not a stock map and no enabled mod has it: upload the map's .zip in the Mods tab first")
    stored = read_json(SETTINGS, {})
    stored["Map"] = path
    write_text(SETTINGS, json.dumps(stored, indent=2, ensure_ascii=False) + "\n")
    out({"ok": True, "map": path, "restartNeeded": True})


def cmd_restart(why="requested from the panel"):
    write_text(RESTART_MARKER, f"requested: {clean(why, 100)}\n")
    sent = console("exit")
    out({"ok": True, "serverStopped": sent,
         "note": None if sent else "The server is not running: the change applies when it next starts."})


# ------------------------------------------------------------------------------------------------
# The server binary: GitHub releases
# ------------------------------------------------------------------------------------------------

def version_of(tag):
    m = re.fullmatch(r"v?(\d{1,3}\.\d{1,3}\.\d{1,3})", str(tag or "").strip())
    return m.group(1) if m else None


def newer(a, b):
    return tuple(int(x) for x in a.split(".")) > tuple(int(x) for x in b.split("."))


def bundled_version():
    return (read("/opt/beammp/VERSION") or "").strip() or None


def latest_release(max_age=6 * 3600):
    """The newest stable release (no pre-releases) as {"version", "url"}, cached in the server volume
    for six hours; the stale cache when GitHub does not answer; None without either."""
    cache = read_json(LATEST_CACHE, {})
    if cache.get("version") and time.time() - cache.get("checked", 0) < max_age:
        return cache
    try:
        req = urllib.request.Request(RELEASES_API + "?per_page=20", headers={"User-Agent": "runonflux-beammp-server-flux", "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=20) as r:
            releases = json.loads(r.read().decode())
        for rel in releases:
            v = version_of(rel.get("tag_name"))
            if not v or rel.get("prerelease") or rel.get("draft"):
                continue
            asset = next((a for a in rel.get("assets", []) if a.get("name") == ASSET), None)
            if asset:
                cache = {"version": v, "url": asset["browser_download_url"], "checked": int(time.time())}
                os.makedirs(SERVER, exist_ok=True)
                write_text(LATEST_CACHE, json.dumps(cache))
                return cache
    except (OSError, ValueError):
        pass
    return cache if cache.get("version") else None


def download_server(version, url):
    """BeamMP-Server <version> into bin/<version>/, checked by running --version. The path, or None."""
    dest_dir = os.path.join(BIN_DIR, version)
    dest = os.path.join(dest_dir, "BeamMP-Server")
    if os.access(dest, os.X_OK):
        return dest
    os.makedirs(dest_dir, exist_ok=True)
    part = dest + ".part"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "runonflux-beammp-server-flux"})
        with urllib.request.urlopen(req, timeout=300) as r, open(part, "wb") as f:
            shutil.copyfileobj(r, f)
        os.chmod(part, 0o755)
        said = subprocess.run([part, "--version"], capture_output=True, text=True, timeout=20).stdout
        if f"v{version}" not in said:
            raise OSError(f"the download says {said.strip()[:80]!r}")
        os.replace(part, dest)
        return dest
    except (OSError, subprocess.SubprocessError) as e:
        print(f"could not install BeamMP-Server {version}: {e}", file=sys.stderr)
        try:
            os.remove(part)
        except OSError:
            pass
        return None


def cmd_server_binary():
    wanted = (env("BEAMMP_VERSION") or "latest").strip().lower()
    path, version = None, None
    if wanted == "latest":
        rel = latest_release()
        if rel:
            version = rel["version"]
            path = download_server(version, rel["url"])
    elif version_of(wanted):
        version = version_of(wanted)
        if version == bundled_version():
            path = BUNDLED
        else:
            path = download_server(version, f"https://github.com/BeamMP/BeamMP-Server/releases/download/v{version}/{ASSET}")
    else:
        print(f"BEAMMP_VERSION '{wanted}' is not a version (3.9.3) or 'latest'", file=sys.stderr)
    if not path:
        if version:
            print(f"falling back to the build in the image ({bundled_version()})", file=sys.stderr)
        path, version = BUNDLED, bundled_version()
    if path == BUNDLED and version and version != bundled_version():
        version = bundled_version()
    write_text(os.path.join(SERVER, "current-version"), f"{version}\n")
    # Older downloads are not needed once a newer one runs: keep the current one only.
    for n in os.listdir(BIN_DIR) if os.path.isdir(BIN_DIR) else []:
        if n != version:
            shutil.rmtree(os.path.join(BIN_DIR, n), ignore_errors=True)
    out({"ok": True, "path": path, "version": version})


def cmd_update_available():
    current = installed_version()
    wanted = (env("BEAMMP_VERSION") or "latest").strip().lower()
    rel = latest_release() if wanted == "latest" else None
    latest = rel["version"] if rel else None
    out({"current": current, "latest": latest, "update": bool(current and latest and newer(latest, current))})


# ------------------------------------------------------------------------------------------------
# Backups and restores (same rules as the other runonflux images)
# ------------------------------------------------------------------------------------------------

def backup_rows():
    reasons = read_json(BACKUP_REASONS, {})
    rows = []
    for n in os.listdir(BACKUPS) if os.path.isdir(BACKUPS) else []:
        if BACKUP_NAME.match(n):
            st = os.stat(os.path.join(BACKUPS, n))
            stamp = calendar.timegm(time.strptime(n[:15], "%Y%m%d-%H%M%S"))
            rows.append({"name": n, "size": st.st_size, "created": int(stamp), "reason": reasons.get(n)})
    return sorted(rows, key=lambda r: r["name"], reverse=True)


def backups_to_prune(rows, keep, now):
    """rows newest first. Keep the newest `keep`, plus the newest one older than a day and the
    newest one older than a week: a server that keeps restarting cannot rotate every good one away."""
    kept = {r["name"] for r in rows[:max(keep, 1)]}
    for age in (86400, 7 * 86400):
        older = next((r for r in rows if now - r["created"] >= age), None)
        if older:
            kept.add(older["name"])
    return [r["name"] for r in rows if r["name"] not in kept]


def cmd_backups():
    pending = read(RESTORE_REQUEST)
    out({"backups": backup_rows(), "pendingRestore": pending.strip() if pending else None})


def make_backup(reason):
    os.makedirs(BACKUPS, exist_ok=True)
    write_text(os.path.join(STATE_DIR, "mods-list.json"), json.dumps([{"file": r["file"], "size": r["size"], "enabled": r["enabled"]} for r in mod_rows()]))
    name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-beammp.tar.gz"
    path = os.path.join(BACKUPS, name)
    while os.path.exists(path):
        time.sleep(1)
        name = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-beammp.tar.gz"
        path = os.path.join(BACKUPS, name)
    part = path + ".part"
    with tarfile.open(part, "w:gz") as tar:
        for item in BACKUP_ITEMS:
            src = os.path.join(DATA, item)
            if os.path.lexists(src):
                tar.add(src, arcname=item)
    os.replace(part, path)
    reasons = read_json(BACKUP_REASONS, {})
    reasons[name] = reason
    names = {r["name"] for r in backup_rows()}
    write_text(BACKUP_REASONS, json.dumps({k: v for k, v in reasons.items() if k in names or k == name}))
    return name


def cmd_backup(reason, force=None):
    rows = backup_rows()
    min_age = int(os.environ.get("FLUX_BACKUP_MIN_AGE_MINUTES", "60") or 60) * 60
    now = time.time()
    if force != "force" and rows and now - rows[0]["created"] < min_age:
        out({"ok": True, "skipped": f"a backup from {int((now - rows[0]['created']) // 60)} min ago is recent enough"})
        return
    name = make_backup(reason)
    pruned = backups_to_prune(backup_rows(), int(os.environ.get("FLUX_BACKUP_KEEP", "10") or 10), now)
    for n in pruned:
        try:
            os.remove(os.path.join(BACKUPS, n))
        except OSError:
            pass
    out({"ok": True, "backup": name, "size": os.path.getsize(os.path.join(BACKUPS, name)), "pruned": pruned})


def cmd_restore(name):
    name = os.path.basename(str(name or "").strip())
    if not BACKUP_NAME.match(name):
        fail("not a backup name")
    if not os.path.isfile(os.path.join(BACKUPS, name)):
        fail("no such backup")
    write_text(RESTORE_REQUEST, name + "\n")
    write_text(RESTART_MARKER, f"requested: restore {name}\n")
    sent = console("exit")
    out({"ok": True, "restoring": name, "serverStopped": sent,
         "note": None if sent else "The server is not running: the backup is restored when it next starts."})


def cmd_apply_restore():
    name = (read(RESTORE_REQUEST) or "").strip()
    if not name:
        out({"ok": True, "restored": None})
        return
    try:
        os.remove(RESTORE_REQUEST)
    except OSError:
        pass
    src = os.path.join(BACKUPS, name)
    if not BACKUP_NAME.match(name) or not os.path.isfile(src):
        fail(f"the backup to restore is gone: {name}")
    safety = make_backup(f"before restoring {name}")
    staging = tempfile.mkdtemp(dir=STATE_DIR, prefix="restore-")
    try:
        with tarfile.open(src, "r:gz") as tar:
            tar.extractall(staging, filter="data")
        for item in BACKUP_ITEMS:
            new, cur = os.path.join(staging, item), os.path.join(DATA, item)
            if not os.path.lexists(new):
                # Not in the backup because it did not exist then (no bans yet, no plugin turned
                # off): it goes, or the restore would keep what was added since.
                if item.startswith("flux/") and item != "flux/mods-list.json" and os.path.lexists(cur):
                    shutil.rmtree(cur) if os.path.isdir(cur) and not os.path.islink(cur) else os.remove(cur)
                continue
            os.makedirs(os.path.dirname(cur), exist_ok=True)
            old = cur + ".flux-old"
            if os.path.lexists(old):
                shutil.rmtree(old) if os.path.isdir(old) and not os.path.islink(old) else os.remove(old)
            if os.path.lexists(cur):
                os.replace(cur, old)
            os.replace(new, cur)
            if os.path.lexists(old):
                shutil.rmtree(old) if os.path.isdir(old) and not os.path.islink(old) else os.remove(old)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    have = {r["file"] for r in mod_rows()}
    listed = read_json(os.path.join(STATE_DIR, "mods-list.json"), [])
    missing = [m.get("file") for m in listed if isinstance(m, dict) and m.get("file") not in have]
    # The env a restored settings.json was made under is not today's: without this, the next apply
    # would see every deploy value as "changed" against the restored record and undo the restore.
    try:
        os.remove(ENV_APPLIED)
    except OSError:
        pass
    seed = {name_: os.environ[name_] for name_ in ENV_KEYS if env(name_)}
    write_text(ENV_APPLIED, json.dumps(seed, indent=2) + "\n")
    out({"ok": True, "restored": name, "safetyBackup": safety, "missingMods": missing})


def main(argv):
    commands = {
        "status": (cmd_status, 0), "files": (cmd_files, 0), "set-map": (cmd_set_map, 1),
        "mod-install": (cmd_mod_install, 1), "mod-enable": (cmd_mod_enable, 2), "mod-protect": (cmd_mod_protect, 2),
        "mod-remove": (cmd_mod_remove, 1), "plugin-install": (cmd_plugin_install, 1),
        "plugin-install-url": (cmd_plugin_install_url, 1), "plugin-enable": (cmd_plugin_enable, 2),
        "plugin-remove": (cmd_plugin_remove, 1), "ban": (cmd_ban, 1), "unban": (cmd_unban, 1),
        "backups": (cmd_backups, 0), "restore": (cmd_restore, 1), "restart": (cmd_restart, (0, 1)),
        "apply": (cmd_apply, 0), "server-binary": (cmd_server_binary, 0), "update-available": (cmd_update_available, 0),
        "backup": (cmd_backup, (1, 2)), "apply-restore": (cmd_apply_restore, 0),
        "plugins-apply": (cmd_plugins_apply, 0), "plugins-discard": (cmd_plugins_discard, 0),
        "apply-plugin-ops": (cmd_apply_plugin_ops, 0),
    }
    if not argv or argv[0] not in commands:
        print(__doc__, file=sys.stderr)
        return 64
    arity = commands[argv[0]][1]
    if len(argv) - 1 not in (arity if isinstance(arity, tuple) else (arity,)):
        print(__doc__, file=sys.stderr)
        return 64
    commands[argv[0]][0](*argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
