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
M.GEAR = { "modem", "geo_scanner", "chest" } -- das soll ein Worker dabeihaben oder daheim in der Toolbox
-- Kurzname -> Teil des Itemnamens
local PATTERN = { modem = "modem", geo_scanner = "geo_scanner", chest = "minecraft:chest",
  player_detector = "player_detector" }
M.GEAR_RETRY = 600 -- Sekunden bis zum naechsten Versuch, fehlende Ausruestung zu holen
M.TOOLBOX_STALE = 600 -- Sekunden: so alt darf das Wissen ueber die Toolbox sein, bevor nachgeschaut wird
M.now = function() return sync.now() end
local lastSay -- letzte Meldung, bleibt auf dem Bildschirm stehen
local printer = print
M.say = function(text)
  lastSay = tostring(text)
  printer(text)
end
-- Tests und andere Aufrufer koennen die Ausgabe umlenken, die letzte Meldung bleibt trotzdem gespeichert
function M.setPrinter(fn) printer = fn end

local FILE = "/.worker"
local state = store.load(FILE) or {}
local lastIdle, lastRefuel, lastGear
local why, fuelWanted -- letzter Grund von der Zentrale, warum es keinen Auftrag gibt
local gearCheckSoon, lastLook -- "fehlt ..." gemeldet: Ausruestung gleich pruefen; letzter Kontrollflug

local function save() store.save(FILE, state) end

function M.state() return state end

local function atHome()
  local p, h = nav.pos(), nav.home()
  return p.x == h.x and p.y == h.y and p.z == h.z
end

-- Heimfliegen; klappt das nicht (z.B. unter der Erde, nach oben nur Fels ausserhalb der Zone), erst durch
-- die eigenen Gaenge zum letzten Einstieg (Startpunkt des letzten Auftrags) und von dort heim
local function goHomeSafe()
  local ok, err = nav.goHome()
  if ok or not state.lastStart then return ok, err end
  local s = state.lastStart
  M.say("Heimweg blockiert, fahre zuerst zum letzten Einstieg " .. s.x .. " " .. s.y .. " " .. s.z)
  local ok2, err2 = nav.goTo(s.x, s.y, s.z, "yxz")
  if not ok2 then return false, "auch der Weg zum Einstieg ist blockiert: " .. tostring(err2) end
  return nav.goHome()
end

-- Toolbox unter dem Heimplatz anschauen und merken (geht nur daheim)
local function noteToolbox()
  if not atHome() then return end
  local seen = gear.toolboxContents()
  if seen then
    state.toolbox = seen
    state.toolboxAt = M.now()
    state.toolboxMissing = nil
  else
    state.toolboxMissing = true -- daheim, aber keine Kiste darunter: Heimplatz pruefen
  end
  save()
end

-- Ausruestung fuer die Zentrale: was die Turtle dabeihat ODER daheim in der Toolbox liegt.
-- Zweiter Wert: true, wenn etwas davon nur daheim liegt (dann rechnet die Zentrale den Umweg ein).
function M.gearInfo()
  local info, needsHome = {}, false
  local toolbox = state.toolbox or {}
  for k, pattern in pairs(PATTERN) do
    local carried = gear.has(pattern)
    info[k] = carried or toolbox[k] == true
    if not carried and toolbox[k] then needsHome = true end
  end
  return info, needsHome
end

-- fehlende Teile (Kurznamen) daheim aus der Toolbox holen; fliegt dafuer heim
local function takeFromHome(missing)
  if not atHome() then
    M.say("Hole " .. table.concat(missing, ", ") .. " aus der Toolbox daheim.")
    local ok, err = goHomeSafe()
    if not ok then
      M.say("Heimweg gescheitert: " .. tostring(err))
      return false, "Heimweg gescheitert: " .. tostring(err)
    end
  end
  noteToolbox()
  local patterns = {}
  for _, k in ipairs(missing) do patterns[#patterns + 1] = PATTERN[k] or k end
  local ok, text = gear.take(patterns)
  noteToolbox() -- was jetzt noch drin liegt
  M.say(ok and ("Ausruestung geholt: " .. table.concat(missing, ", ")) or tostring(text))
  return ok, text
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
    local d, h = nav.depot(), nav.home()
    local gearInfo, needsHome = M.gearInfo()
    n:send("job", "worker.idle", {
      role = settings.get("claude.role", "miner"),
      gear = gearInfo,
      needs_home = needsHome,
      home = { x = h.x, y = h.y, z = h.z },
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
  elseif msg.topic == "job.none" then
    why = p.reasons
    fuelWanted = tonumber(p.need_fuel)
    if why and why:find("fehlt", 1, true) then gearCheckSoon = true end
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
    why, fuelWanted = nil, nil
    state.job = { id = p.id, epoch = p.epoch, type = p.type, params = p.params or {}, area = p.area,
      requires = p.requires }
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
  -- Worker fahren nach jedem Mining-Auftrag zum Lager und heim, auch nach einem Tunnel:
  -- sonst bleiben sie unter der Erde stecken und kommen ohne Zone nicht mehr nach oben
  if opts.home == nil then opts.home = true end
  return opts
end


-- Leerlauf: Ausruestung pruefen.
--   daheim:     Toolbox anschauen und fehlende Teile, die drin liegen, mitnehmen
--   unterwegs:  nur heimfliegen, wenn das Modem fehlt (ohne kann sie nicht funken) oder die Toolbox noch
--               nie angeschaut wurde. Sonst zaehlt, was daheim liegt - geholt wird es erst fuer einen Auftrag.
local function idleGear()
  noteToolbox()
  local missing = {}
  for _, k in ipairs(M.GEAR) do
    if not gear.has(PATTERN[k]) then missing[#missing + 1] = k end -- Modem darf fest ausgeruestet sein
  end
  if #missing == 0 then return nil end
  if atHome() then
    local available = {}
    for _, k in ipairs(missing) do
      if (state.toolbox or {})[k] then available[#available + 1] = k end
    end
    if #available == 0 then return nil end
    return (takeFromHome(available))
  end
  -- Modem fehlt, Toolbox nie gesehen, oder die Zentrale sagt "fehlt ..." und das Wissen ist veraltet.
  -- Kontrollfluege hoechstens alle TOOLBOX_STALE Sekunden, falls die Toolbox gar nicht lesbar ist.
  local now = M.now()
  local stale = not state.toolboxAt or now - state.toolboxAt > M.TOOLBOX_STALE * 1000
  local mayLook = not lastLook or now - lastLook >= M.TOOLBOX_STALE * 1000
  if not gear.has("modem") or ((state.toolbox == nil or (why and why:find("fehlt", 1, true) and stale)) and mayLook) then
    lastLook = now
    sync.setJob("Ausruestung holen")
    local ok = takeFromHome(missing)
    sync.setJob(nil)
    return ok
  end
  return nil
end

-- fuehrt den Auftrag aus und liefert den Ergebnistext ("Fertig. ..." oder "Gestoppt: ...")
local function runJob(job)
  sync.setJob(job.id .. " " .. job.type)
  if mine.pendingJob() then
    local res = mine.resume(M.say) -- nach einem Neustart dort weitermachen
    if res then return res end
  end
  -- was der Auftrag braucht und nur daheim in der Toolbox liegt, jetzt holen
  local missing = {}
  for _, k in ipairs(job.requires or {}) do
    if not gear.has(PATTERN[k] or k) then missing[#missing + 1] = k end
  end
  if #missing > 0 then
    sync.setJob(job.id .. " Ausruestung holen")
    takeFromHome(missing)
    local still = {}
    for _, k in ipairs(missing) do
      if not gear.has(PATTERN[k] or k) then still[#still + 1] = k end
    end
    if #still > 0 then return "Gestoppt: Ausruestung fehlt: " .. table.concat(still, ", ") end
    sync.setJob(job.id .. " " .. job.type)
  end
  local p = job.params or {}
  if p.start then
    local ok, err = nav.travel(p.start.x, p.start.y, p.start.z)
    if not ok then return "Gestoppt: Anfahrt gescheitert: " .. tostring(err) end
    nav.face(p.start.f or 0)
    -- Einstieg merken: von hier kommt die Turtle sicher wieder nach oben
    state.lastStart = { x = p.start.x, y = p.start.y, z = p.start.z }
    save()
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
  if not state.paused and (gearCheckSoon or not lastGear or now - lastGear >= M.GEAR_RETRY * 1000) then
    lastGear, gearCheckSoon = now, false
    local ok, refilled = pcall(idleGear)
    if ok and refilled then return "ausgeruestet" end
  end
  -- zu wenig Fuel: unter der Mindestmenge, oder die Zentrale sagt, fuer einen Auftrag reicht es nicht.
  -- Dann selbst zum Lager fahren und so viel tanken, wie gebraucht wird (dort wird auch ausgeladen).
  local wanted = math.max(M.MIN_FUEL, fuelWanted or 0)
  if not state.paused and nav.fuel() < wanted
    and (not lastRefuel or now - lastRefuel >= M.REFUEL_RETRY * 1000) then
    lastRefuel = now
    sync.setJob("tanken")
    local target = nav.FUEL_TARGET
    nav.FUEL_TARGET = math.max(target, wanted + 100)
    local ok = pcall(function()
      if not nav.goDepot() then -- vielleicht unter der Erde: erst zum Einstieg
        assert(goHomeSafe())
        assert(nav.goDepot())
      end
      nav.unload()
      assert(goHomeSafe())
    end)
    nav.FUEL_TARGET = target
    sync.setJob(nil)
    fuelWanted = nil
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
    if why then lines[#lines + 1] = "Kein passender: " .. why end
  end
  -- was die Turtle ueber ihre Toolbox daheim weiss
  if state.toolboxMissing then
    lines[#lines + 1] = "Toolbox: keine Kiste unter dem Heimplatz gefunden (Heimplatz pruefen)"
  elseif state.toolbox then
    local items = {}
    for k in pairs(state.toolbox) do items[#items + 1] = k end
    table.sort(items)
    local age = state.toolboxAt and math.floor((M.now() - state.toolboxAt) / 60000) or 0
    lines[#lines + 1] = ("Toolbox daheim: %s (vor %d min angeschaut)"):format(
      #items > 0 and table.concat(items, ", ") or "leer", age)
  else
    lines[#lines + 1] = "Toolbox daheim: noch nie angeschaut"
  end
  lines[#lines + 1] = "Fuel: " .. tostring(nav.fuel())
  if lastSay then lines[#lines + 1] = "Letzte Meldung: " .. lastSay end
  lines[#lines + 1] = nav.where()
  lines[#lines + 1] = sync.describe()
  return lines
end

return M
