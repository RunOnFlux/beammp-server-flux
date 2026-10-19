-- FluxAdmin: the server plugin built into runonflux/beammp-server-flux.
--
-- BeamMP has no bans and no machine-readable player list of its own: its console's `list` prints
-- names in columns and `kick` matches a name by PREFIX (kicking "Al" can kick "Alice"). This plugin
-- gives the Flux panel both, through the console:
--
--   flux players          one line, FLUXJSON {"players":[{"id","name","beammp","ip","guest","cars"}]}
--   flux kick <id> [why]  drops exactly that player (the id from `flux players`)
--   flux ban <id> [why]   adds that player to the ban list (account id, name, IP) and drops them
--
-- and enforces the ban list the panel keeps in <data>/flux/bans.json (written by `flux-beammp ban`
-- / `unban`, read again on every join, so a ban needs no reload):
--
--   [{"beammp": "123456", "name": "Someone", "ip": "203.0.113.4", "reason": "..."}]
--
-- A ban matches the BeamMP account id when it has one (a name can be changed on the forum), else
-- the name (case-insensitive), else the IP. Guests have no account id.
--
-- The image puts this folder back on every start: edits here are lost. Your own plugins go in
-- folders of their own next to it.

local DATA = os.getenv("FLUX_DATA_DIR") or "/mnt/beammp/data"
local BANS = DATA .. "/flux/bans.json"

local function readBans()
  local f = io.open(BANS, "r")
  if not f then return {} end
  local text = f:read("a")
  f:close()
  if not text or text == "" then return {} end
  local ok, data = pcall(Util.JsonDecode, text)
  if ok and type(data) == "table" then return data end
  print("FluxAdmin: " .. BANS .. " is not valid JSON; no bans are enforced until it is fixed")
  return {}
end

local function lower(s) return string.lower(tostring(s or "")) end

-- The ban list is also written by `flux-beammp ban` / `unban` (the panel's Bans tab); both read
-- the file fresh and write it whole, at human speed.
local function writeBans(bans)
  local tmp = BANS .. ".flux-lua"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(#bans == 0 and "[]" or Util.JsonEncode(bans))
  f:write("\n")
  f:close()
  return os.rename(tmp, BANS)
end

local function banFor(name, ids)
  local beammp = ids and ids.beammp and tostring(ids.beammp) or nil
  local ip = ids and ids.ip and tostring(ids.ip) or nil
  for _, b in ipairs(readBans()) do
    if type(b) == "table" then
      if b.beammp and beammp and tostring(b.beammp) == beammp then return b end
      if (not b.beammp or b.beammp == "") and b.name and b.name ~= "" and lower(b.name) == lower(name) then return b end
      if b.ip and b.ip ~= "" and ip and tostring(b.ip) == ip then return b end
    end
  end
  return nil
end

function FluxOnAuth(name, role, isGuest, identifiers)
  local b = banFor(name, identifiers)
  if b then
    print("FluxAdmin: refused " .. tostring(name) .. " (banned)")
    local why = (b.reason and b.reason ~= "") and (": " .. b.reason) or ""
    return "You are banned from this server" .. why
  end
end

local function players()
  local rows = {}
  for id, name in pairs(MP.GetPlayers() or {}) do
    local ids = MP.GetPlayerIdentifiers(id) or {}
    local cars = 0
    local ok, vehicles = pcall(MP.GetPlayerVehicles, id)
    if ok and type(vehicles) == "table" then
      for _ in pairs(vehicles) do cars = cars + 1 end
    end
    local guest = false
    local okg, g = pcall(MP.IsPlayerGuest, id)
    if okg then guest = g and true or false end
    table.insert(rows, {
      id = id,
      name = name,
      beammp = ids.beammp and tostring(ids.beammp) or nil,
      ip = ids.ip and tostring(ids.ip) or nil,
      guest = guest,
      cars = cars,
    })
  end
  table.sort(rows, function(a, b) return a.id < b.id end)
  return rows
end

function FluxOnConsole(cmd)
  local verb, rest = string.match(cmd or "", "^flux%s+(%S+)%s*(.*)$")
  if not verb then return nil end
  if verb == "players" then
    local rows = players()
    -- An empty Lua table encodes as {} (an object): spelled out so the list is always an array.
    if #rows == 0 then return 'FLUXJSON {"players":[]}' end
    return "FLUXJSON " .. Util.JsonEncode({ players = rows })
  elseif verb == "kick" then
    local id, why = string.match(rest, "^(%d+)%s*(.*)$")
    id = tonumber(id)
    if not id or not (MP.GetPlayers() or {})[id] then
      return "FLUXJSON " .. Util.JsonEncode({ ok = false, error = "no player with that id" })
    end
    local name = MP.GetPlayerName(id)
    MP.DropPlayer(id, (why and why ~= "") and why or "Kicked by the server owner")
    return "FLUXJSON " .. Util.JsonEncode({ ok = true, kicked = name })
  elseif verb == "ban" then
    local id, why = string.match(rest, "^(%d+)%s*(.*)$")
    id = tonumber(id)
    if not id or not (MP.GetPlayers() or {})[id] then
      return "FLUXJSON " .. Util.JsonEncode({ ok = false, error = "no player with that id" })
    end
    local name = MP.GetPlayerName(id)
    local ids = MP.GetPlayerIdentifiers(id) or {}
    local entry = { name = name, reason = (why and why ~= "") and why or nil, at = os.time() }
    if ids.beammp then entry.beammp = tostring(ids.beammp) end
    -- A guest has no account: the ban holds its name and its address.
    if not ids.beammp and ids.ip then entry.ip = tostring(ids.ip) end
    local bans = {}
    for _, b in ipairs(readBans()) do
      local same = (entry.beammp and b.beammp and tostring(b.beammp) == entry.beammp)
        or (not entry.beammp and not b.beammp and lower(b.name) == lower(name))
      if not same then table.insert(bans, b) end
    end
    table.insert(bans, entry)
    if not writeBans(bans) then
      return "FLUXJSON " .. Util.JsonEncode({ ok = false, error = "could not write " .. BANS })
    end
    MP.DropPlayer(id, "You are banned from this server" .. ((why and why ~= "") and (": " .. why) or ""))
    return "FLUXJSON " .. Util.JsonEncode({ ok = true, banned = name })
  end
  return "FLUXJSON " .. Util.JsonEncode({ ok = false, error = "unknown flux command: " .. verb })
end

MP.RegisterEvent("onPlayerAuth", "FluxOnAuth")
MP.RegisterEvent("onConsoleInput", "FluxOnConsole")
print("FluxAdmin ready (bans: " .. BANS .. ")")
