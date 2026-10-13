-- sync.lua - TurtleMQ auf der Turtle: Sync-Fenster und Heartbeat
--
-- Turtles haben kein festes Modem (Spitzhacke + Chat Box). Fuer ein Sync-Fenster wird das Modem aus
-- dem Inventar kurz statt der Spitzhacke angelegt (gear.with), die Chat Box bleibt dran:
--   Heartbeat in die Outbox -> Modem an -> Outbox senden -> Post vom Gateway empfangen -> Modem ab
-- Ein Sync zaehlt als Lebenszeichen. Er laeuft nur an sicheren Stellen: zwischen zwei Mining-Schritten
-- (mine.lua, maintain), im Leerlauf von claude und am Ende eines Auftrags.
--
--   set mq.enabled true      einschalten (Standard: aus)
--   set mq.interval 60       Sekunden zwischen zwei Syncs

local mq = require("mq")
local gear = require("gear")
local nav = require("nav")
local version = require("version")

local M = {}

M.now = function() return os.epoch("utc") end
-- macht aus dem Modem-Peripheral eine Funkverbindung (Tests ersetzen das durch ein simuliertes Netz)
M.linkFor = function(modem) return mq.modemLink(modem) end
-- wird fuer jede empfangene Nachricht aufgerufen (claude.lua haengt sich hier ein)
M.onMessage = function(msg)
  print(("[MQ] %s von #%s"):format(tostring(msg.topic), tostring(msg.source)))
end

local node, lastSync, job, registered = nil, nil, nil, false
M.last = nil -- Ergebnis des letzten Syncs (fuer status)

function M.enabled() return settings.get("mq.enabled", false) == true end
function M.interval() return settings.get("mq.interval", 60) end

-- aktueller Auftrag fuer den Heartbeat, z.B. "orehunt 2/4" (nil = keiner)
function M.setJob(text) job = text end

local function getNode()
  if not node then node = mq.new({ dir = "/.mq", now = M.now }) end
  return node
end

M.getNode = function() return getNode() end

function M.heartbeat()
  local p = nav.pos()
  local fuel = nav.fuel()
  return {
    label = os.getComputerLabel(),
    role = settings.get("claude.role", "turtle"),
    version = version.text(),
    pos = { x = p.x, y = p.y, z = p.z },
    gps = nav.hasGps(),
    fuel = fuel == math.huge and "unbegrenzt" or fuel,
    job = job or false, -- false statt nil, sonst bliebe am Gateway der alte Auftrag stehen
    interval = M.interval(),
    mode = "sync", -- hoert nur im Sync-Fenster zu
  }
end

local function wirelessSide()
  for _, side in ipairs({ "left", "right" }) do
    if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then return side end
  end
end

-- fn(link) mit Funkverbindung ausfuehren: festes Wireless-Modem oder kurz eingewechselt
local function withLink(fn)
  local side = wirelessSide()
  if side then return true, fn(M.linkFor(peripheral.wrap(side))) end
  local result
  local ok, err = gear.with("modem", function(modem)
    result = fn(M.linkFor(modem))
    return true
  end)
  if not ok then return false, err end
  return true, result
end

-- Jetzt syncen (wenn eingeschaltet). Gibt true/false und eine kurze Beschreibung zurueck.
function M.run()
  if not M.enabled() then return false, "TurtleMQ ist aus (set mq.enabled true)" end
  lastSync = M.now()
  local n = getNode()
  -- nur der neueste Heartbeat zaehlt, aeltere ungesendete muessen nicht mehr raus
  n:drop(function(m) return m.topic == "worker.heartbeat" end)
  n:send("gateway", "worker.heartbeat", M.heartbeat(), { ttl = 600 })
  if not registered then
    n:drop(function(m) return m.topic == "mq.register" end)
    n:register({}, { label = os.getComputerLabel(), role = settings.get("claude.role", "turtle"), mode = "sync" })
  end

  local ok, res = withLink(function(link)
    n.link = link
    n.done = false -- mq.done kann schon kommen, waehrend flush noch auf ACKs wartet
    local r = n:flush({ force = true })
    -- Post abholen: zuhoeren, bis das Gateway "mq.done" schickt (hoechstens 5 s, falls es gerade beschaeftigt ist)
    r.received = n:poll(5, { untilDone = true })
    r.done = n.done
    n.link = nil
    if link.close then link.close() end
    return r
  end)
  local handled = n:process(function(msg) M.onMessage(msg) end)

  if not ok then
    M.last = { ok = false, at = lastSync, text = "kein Sync: " .. tostring(res) }
    return false, M.last.text
  end
  if res.acked > 0 then registered = true end
  M.last = {
    ok = true, at = lastSync,
    text = ("gesendet %d, bestaetigt %d, empfangen %d, offen %d"):format(res.sent, res.acked, handled, n:pending()),
  }
  return true, M.last.text
end

-- Syncen, falls das Intervall um ist. An sicheren Stellen aufrufen.
function M.maybe()
  if not M.enabled() then return false end
  if lastSync and M.now() - lastSync < M.interval() * 1000 then return false end
  return M.run()
end

-- fuer status: eine Zeile
function M.describe()
  if not M.enabled() then return "TurtleMQ: aus" end
  local n = getNode()
  local last = M.last and (("vor %ds, %s"):format(math.floor((M.now() - M.last.at) / 1000), M.last.text))
    or "noch kein Sync"
  return ("TurtleMQ: an (alle %ds), letzter Sync %s, Outbox %d"):format(M.interval(), last, n:pending())
end

return M
