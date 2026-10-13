-- jobrunner.lua - Worker-Dienst einer Miner-Turtle: Auftraege von der Zentrale annehmen und abarbeiten
--
--   Leerlauf:  alle IDLE_INTERVAL Sekunden Sync mit worker.idle (Rolle, Ausruestung, Position, Fuel)
--   job.assign kommt beim naechsten Sync -> job.accept -> Auftrag mit den vorhandenen Programmen
--   ausfuehren (alle Schutzregeln gelten) -> waehrenddessen job.progress bei jedem Sync (verlaengert
--   die Lease) -> job.complete oder job.fail
--   job.cancel / job.revoke: laufenden Auftrag sofort abbrechen
--
-- Der Zustand liegt in /.worker. Nach einem Neustart wird ein unterbrochener Auftrag fortgesetzt und
-- ein schon fertiges, aber noch nicht gemeldetes Ergebnis erneut gemeldet (die Zentrale ignoriert Doppelte).

local store = require("store")
local nav = require("nav")
local mine = require("mine")
local gear = require("gear")
local sync = require("sync")
local zones = require("zones")

local M = {}

M.IDLE_INTERVAL = settings.get("worker.idle_interval", 15) -- Sekunden zwischen zwei Leerlauf-Syncs
M.MIN_FUEL = settings.get("worker.min_fuel", 1000) -- darunter faehrt der Worker im Leerlauf tanken
M.REFUEL_RETRY = 600 -- Sekunden bis zum naechsten Tankversuch, wenn es nicht geklappt hat
M.GEAR = { "modem", "geo_scanner", "minecraft:chest" } -- das soll ein Worker immer dabeihaben
M.GEAR_RETRY = 600 -- Sekunden bis zum naechsten Versuch, fehlende Ausruestung zu holen
M.say = print
M.now = function() return sync.now() end

local FILE = "/.worker"
local state = store.load(FILE) or {}
local lastIdle, lastRefuel, lastGear

local function save() store.save(FILE, state) end

function M.state() return state end

function M.gearInfo()
  return {
    geo_scanner = gear.findSlot("geo_scanner") ~= nil,
    player_detector = gear.findSlot("player_detector") ~= nil,
    modem = gear.findSlot("modem") ~= nil,
    chest = gear.findSlot("minecraft:chest") ~= nil,
  }
end

local function only(n, topic)
  n:drop(function(m) return m.topic == topic end)
end

-- bei jedem Sync: Stand der zentralen Karte erfragen, angenommenen Auftrag melden, Fortschritt oder "frei"
local function hook(n)
  only(n, "map.get")
  n:send("map", "map.get", { rev = zones.rev() }, { ttl = 120 })
  local job = state.job
  if job and job.result == nil and not job.stop then
    if not job.accepted then
      n:send("job", "job.accept", { id = job.id, epoch = job.epoch })
      job.accepted = true
      save()
    end
    only(n, "job.progress")
    n:send("job", "job.progress", { id = job.id, epoch = job.epoch, progress = sync.getJob() or "Anfahrt" },
      { ttl = 600 })
  elseif not job and not state.paused then
    only(n, "worker.idle")
    local p, fuel = nav.pos(), nav.fuel()
    local d = nav.depot()
    n:send("job", "worker.idle", {
      role = settings.get("claude.role", "miner"),
      gear = M.gearInfo(),
      pos = { x = p.x, y = p.y, z = p.z },
      fuel = fuel == math.huge and 1000000 or fuel,
      depot = d and { x = d.x, y = d.y, z = d.z } or nil,
      travel_y = nav.TRAVEL_Y,
    }, { ttl = 120 })
  end
end

-- neuer Stand vom Map-Dienst: Zonen ersetzen, Lagerplatz und eigenen Heimplatz uebernehmen
local function applyMap(p)
  if (tonumber(p.rev) or 0) <= zones.rev() then return end
  zones.replace(p.zones, p.maxY, p.rev)
  local places = type(p.places) == "table" and p.places or {}
  if places.depot then nav.setDepot(places.depot) end
  local mine = os.getComputerLabel() and places["home:" .. os.getComputerLabel()]
  if mine then nav.setHome(mine) end
  M.say(("Karte Stand %d uebernommen: %d Zonen"):format(p.rev, #(p.zones or {})))
end

local function onMessage(msg)
  local p = type(msg.payload) == "table" and msg.payload or {}
  if msg.topic == "map.data" then
    applyMap(p)
  elseif msg.topic == "job.assign" then
    local job = state.job
    if job then
      if job.id == p.id then
        job.epoch = p.epoch -- dieselbe Arbeit, nur neu zugeteilt
        save()
      else
        sync.getNode():send("job", "job.fail", { id = p.id, epoch = p.epoch, reason = "Worker beschaeftigt",
          retry = true })
      end
      return
    end
    state.job = { id = p.id, epoch = p.epoch, type = p.type, params = p.params or {}, area = p.area }
    save()
    M.say(("Neuer Auftrag %s: %s"):format(tostring(p.id), tostring(p.type)))
  elseif msg.topic == "job.cancel" or msg.topic == "job.revoke" then
    local job = state.job
    if job and job.id == p.id and job.result == nil then
      job.stop = msg.topic == "job.cancel" and "abgebrochen (Zentrale)" or "entzogen (Lease abgelaufen)"
      save()
      nav.abort()
      M.say(job.id .. ": " .. job.stop)
    end
  else
    M.say(("[MQ] %s von #%s"):format(tostring(msg.topic), tostring(msg.source)))
  end
end

function M.init()
  sync.addHook(hook)
  sync.onMessage = onMessage
end

local function copyParams(p)
  local opts = {}
  for k, v in pairs(p or {}) do
    if k ~= "start" then opts[k] = v end
  end
  opts.keep_gear = true -- Worker legen ihre Ausruestung nie in die Toolbox
  return opts
end

-- fehlende Ausruestung (Modem, Geo Scanner, Kiste) aus der Toolbox unter dem Heimplatz holen
local function refillGear()
  local missing = {}
  for _, item in ipairs(M.GEAR) do
    if not gear.findSlot(item) then missing[#missing + 1] = item end
  end
  if #missing == 0 then return nil end
  local p, h = nav.pos(), nav.home()
  if p.x ~= h.x or p.y ~= h.y or p.z ~= h.z then return nil end -- die Toolbox gibt es nur daheim
  local ok, text = gear.take(missing)
  M.say(ok and ("Ausruestung geholt: " .. table.concat(missing, ", ")) or tostring(text))
  return ok
end

-- fuehrt den Auftrag aus und liefert den Ergebnistext ("Fertig. ..." oder "Gestoppt: ...")
local function runJob(job)
  sync.setJob(job.id .. " " .. job.type)
  if mine.pendingJob() then
    local res = mine.resume(M.say) -- nach einem Neustart dort weitermachen
    if res then return res end
  end
  local p = job.params or {}
  if p.start then
    local ok, err = nav.travel(p.start.x, p.start.y, p.start.z)
    if not ok then return "Gestoppt: Anfahrt gescheitert: " .. tostring(err) end
    nav.face(p.start.f or 0)
  end
  if job.type == "orehunt" or job.type == "stripmine" or job.type == "tunnel" then
    return mine.run(mine[job.type], copyParams(p), M.say)
  elseif job.type == "goto" then
    local ok, err = nav.travel(p.x, p.y, p.z)
    return ok and ("Fertig. " .. nav.where()) or ("Gestoppt: " .. tostring(err))
  elseif job.type == "gohome" then
    local ok, err = nav.goDepot()
    if not ok then return "Gestoppt: " .. tostring(err) end
    nav.unload()
    ok, err = nav.goHome()
    return ok and ("Fertig. " .. nav.where()) or ("Gestoppt: " .. tostring(err))
  end
  return "Gestoppt: unbekannter Auftragstyp " .. tostring(job.type)
end

-- Eine Runde: Auftrag ausfuehren und melden, sonst im Leerlauf regelmaessig syncen
function M.step()
  if not sync.enabled() then return "aus" end
  local job = state.job
  if job and job.result == nil and not job.stop then
    nav.resetAbort() -- alte Abbrueche vergessen; VOR dem Sync, sonst ginge ein frischer job.cancel verloren
    if not job.accepted then pcall(sync.run) end -- Annahme sofort melden (dabei kann schon cancel kommen)
    local res
    if job.stop then
      res = "Gestoppt: " .. job.stop
    else
      local ok, r = pcall(runJob, job)
      res = ok and r or ("Gestoppt: " .. tostring(r))
      if job.stop then res = "Gestoppt: " .. job.stop end
    end
    job.result = res
    save()
  end
  if job then
    local success = job.result ~= nil and job.result:find("^Fertig") ~= nil and not job.stop
    local n = sync.getNode()
    if success then
      n:send("job", "job.complete", { id = job.id, epoch = job.epoch, result = job.result:sub(1, 300) })
    else
      n:send("job", "job.fail", { id = job.id, epoch = job.epoch,
        reason = tostring(job.result or job.stop):sub(1, 300), retry = not job.stop })
    end
    state.job = nil
    save()
    sync.setJob(nil)
    pcall(sync.run)
    return success and "fertig" or "fehlgeschlagen"
  end
  local now = M.now()
  -- fehlt etwas von der Ausruestung, daheim aus der Toolbox holen
  if not state.paused and (not lastGear or now - lastGear >= M.GEAR_RETRY * 1000) then
    lastGear = now
    local ok, refilled = pcall(refillGear)
    if ok and refilled then return "ausgeruestet" end
  end
  -- zu wenig Fuel fuer Auftraege: selbst zum Lager fahren und tanken (dort wird auch ausgeladen)
  if not state.paused and nav.fuel() < M.MIN_FUEL
    and (not lastRefuel or now - lastRefuel >= M.REFUEL_RETRY * 1000) then
    lastRefuel = now
    sync.setJob("tanken")
    local ok = pcall(function()
      assert(nav.goDepot())
      nav.unload()
      assert(nav.goHome())
    end)
    sync.setJob(nil)
    pcall(sync.run)
    return ok and "getankt" or "tanken gescheitert"
  end
  if not state.paused and (not lastIdle or now - lastIdle >= M.IDLE_INTERVAL * 1000) then
    lastIdle = now
    pcall(sync.run)
  end
  return "leerlauf"
end

function M.togglePause()
  state.paused = not state.paused
  save()
  return state.paused
end

-- Zeilen fuer die Anzeige
function M.status()
  local lines = {}
  local job = state.job
  if job then
    lines[#lines + 1] = ("Auftrag %s: %s  %s"):format(job.id, job.type, sync.getJob() or "")
  elseif state.paused then
    lines[#lines + 1] = "PAUSIERT: keine neuen Auftraege (P = weiter)"
  else
    lines[#lines + 1] = "Wartet auf Auftrag"
  end
  lines[#lines + 1] = "Fuel: " .. tostring(nav.fuel())
  lines[#lines + 1] = nav.where()
  lines[#lines + 1] = sync.describe()
  return lines
end

return M
