-- broker.lua - Logik des Gateways (TurtleMQ-Broker)
--
-- Das Gateway nimmt jede Nachricht an (mq-Knoten mit accept = alles) und gibt sie hier an route():
--   * Steuerung:   mq.register (Namen/Infos), mq.subscribe/unsubscribe (Topics), mq.fetch, system.discovery
--   * Zustellung:  an Computer-ID, an registrierten Namen (wartet, bis sich jemand unter dem Namen meldet),
--                  an "*" (alle bekannten Geraete) oder an "gateway" (nur an Abonnenten)
--   * Abonnenten:  bekommen eine Kopie jeder Nachricht, deren Topic passt ("worker.*", "*", genauer Name)
--   * Status:      jede Nachricht zaehlt als Lebenszeichen, worker.heartbeat liefert Position, Fuel, Auftrag
--
-- Postfach = Outbox des Gateways mit dem Geraet als Ziel. Meldet sich ein Geraet, schickt das Gateway
-- ihm sofort seine Post (siehe gateway.lua). Persistiert in /.gateway/state.

local store = require("store")

local M = {}
M.DEFAULT_INTERVAL = 60 -- Sekunden zwischen Lebenszeichen, wenn ein Geraet nichts anderes meldet
M.LOG_SIZE = 20

local Broker = {}
Broker.__index = Broker

function M.new(node, opts)
  opts = opts or {}
  local self = setmetatable({}, Broker)
  self.node = node
  self.dir = opts.dir or "/.gateway"
  fs.makeDir(self.dir)
  self.log = {}
  self.state = store.load(self.dir .. "/state") or {}
  self.state.devices = self.state.devices or {}
  self.state.names = self.state.names or {}
  self.state.subs = self.state.subs or {}
  return self
end

function Broker:save()
  store.save(self.dir .. "/state", self.state)
end

local function matches(pattern, topic)
  if pattern == "*" then return true end
  if pattern:sub(-1) == "*" then return topic:sub(1, #pattern - 1) == pattern:sub(1, -2) end
  return pattern == topic
end

function Broker:device(id)
  local d = self.state.devices[id]
  if not d then
    d = { id = id }
    self.state.devices[id] = d
  end
  return d
end

-- Ziel aufloesen: Computer-ID, registrierter Name, oder nil (Name noch unbekannt)
function Broker:resolve(target)
  if type(target) == "number" then return target end
  return self.state.names[target]
end

function Broker:deliver(msg, to, done)
  if to == nil or to == msg.source or done[to] then return end
  done[to] = true
  self.node:forward(msg, to)
end

-- Nachrichten, die an einen bisher unbekannten Namen warten, an die jetzt bekannte ID umleiten
function Broker:rerouteName(name, id)
  for _, m in ipairs(self.node:list("outbox")) do
    if m.target == name then
      self.node:forward(m, id)
      local file = self.node:path("outbox", m.key or m.id)
      for _, suffix in ipairs({ "", ".bak", ".tmp" }) do
        if fs.exists(file .. suffix) then fs.delete(file .. suffix) end
      end
    end
  end
end

local HEARTBEAT_FIELDS = { "label", "role", "version", "pos", "fuel", "job", "interval", "offline_until", "note",
  "mode" }

function Broker:route(msg)
  local now = self.node.now()
  local d = self:device(msg.source)
  d.last_seen = now
  table.insert(self.log, 1, { ts = now, source = msg.source, target = msg.target, topic = msg.topic })
  while #self.log > M.LOG_SIZE do table.remove(self.log) end

  local p = type(msg.payload) == "table" and msg.payload or {}
  local topic = msg.topic or ""

  if topic == "mq.register" then
    for _, field in ipairs(HEARTBEAT_FIELDS) do
      if p[field] ~= nil then d[field] = p[field] end
    end
    d.names = p.names
    for _, name in ipairs(p.names or {}) do
      self.state.names[name] = msg.source
      self:rerouteName(name, msg.source)
    end
  elseif topic == "mq.subscribe" then
    for _, pattern in ipairs(p.topics or {}) do
      self.state.subs[pattern] = self.state.subs[pattern] or {}
      self.state.subs[pattern][msg.source] = true
    end
  elseif topic == "mq.unsubscribe" then
    for _, pattern in ipairs(p.topics or {}) do
      if self.state.subs[pattern] then self.state.subs[pattern][msg.source] = nil end
    end
  elseif topic == "mq.fetch" then
    -- nur Lebenszeichen; die Post schickt gateway.lua, weil sich das Geraet gemeldet hat
  elseif topic == "system.discovery" then
    local devices = {}
    for id, dev in pairs(self.state.devices) do
      devices[#devices + 1] = { id = id, label = dev.label, role = dev.role, names = dev.names }
    end
    self.node:send(msg.source, "system.directory", { names = self.state.names, devices = devices },
      { reply_to = msg.id })
  else
    if topic == "worker.heartbeat" then
      for _, field in ipairs(HEARTBEAT_FIELDS) do
        if p[field] ~= nil then d[field] = p[field] end
      end
    end
    local done = {}
    local target = msg.target
    if target == "*" then
      for id in pairs(self.state.devices) do self:deliver(msg, id, done) end
    elseif target ~= "gateway" and target ~= self.node.id then
      local to = self:resolve(target)
      if to then
        self:deliver(msg, to, done)
      else
        self.node:forward(msg, target) -- wartet, bis sich jemand unter diesem Namen anmeldet
      end
    end
    for pattern, ids in pairs(self.state.subs) do
      if matches(pattern, topic) then
        for id in pairs(ids) do self:deliver(msg, id, done) end
      end
    end
  end
  self:save()
end

-- Sync-Geraete (Turtles) hoeren nur im Sync-Fenster zu: an sie wird nur beim Kontakt gesendet
function Broker:isSync(id)
  local d = self.state.devices[id]
  return d ~= nil and d.mode == "sync"
end

-- Eine Runde der Gateway-Schleife (gateway.lua ruft das endlos auf, Tests einzeln):
--   1. empfangen (sofort weiter, wenn schon etwas in der Inbox liegt)
--   2. alles verarbeiten und verteilen
--   3. wer sich gemeldet hat, bekommt jetzt seine Post und danach "mq.done"
--   4. Wiederholungen fuer Geraete mit festem Modem; Sync-Geraete und unbekannte Namen warten
function Broker:step(timeout)
  local node = self.node
  local backlog = #node:list("inbox") > 0
  node:poll(backlog and 0 or (timeout or 1), { quiet = 0.2 })
  local active = {}
  node:process(function(msg)
    active[msg.source] = true
    self:route(msg)
  end)
  for id in pairs(active) do
    if type(id) == "number" then
      if node:pending(id) > 0 then node:flush({ target = id, force = true }) end
      node:hint(id, "mq.done")
    end
  end
  node:flush({ skip = function(m) return type(m.target) ~= "number" or self:isSync(m.target) end })
end

-- Zustand eines Geraets nach Whitepaper 5.3
function Broker:stateOf(d, now)
  if not d.last_seen then return "unbekannt" end
  if d.offline_until and now < d.offline_until then return "offline (angekuendigt)" end
  local interval = (d.interval or M.DEFAULT_INTERVAL) * 1000
  local age = now - d.last_seen
  if age < 1.5 * interval then return "online" end
  if age < 3 * interval then return "verspaetet" end
  if age < 10 * interval then return "overdue" end
  return "lost"
end

local function ago(ms)
  local s = math.floor(ms / 1000)
  if s < 120 then return s .. "s" end
  if s < 7200 then return math.floor(s / 60) .. "min" end
  return math.floor(s / 3600) .. "h"
end

-- Eine Zeile pro Geraet fuer den Bildschirm des Gateways
function Broker:statusLines(now)
  now = now or self.node.now()
  local list = {}
  for _, d in pairs(self.state.devices) do list[#list + 1] = d end
  table.sort(list, function(a, b) return tostring(a.label or a.id) < tostring(b.label or b.id) end)
  local lines = {}
  for _, d in ipairs(list) do
    local parts = {
      tostring(d.label or ("#" .. d.id)),
      self:stateOf(d, now),
      d.last_seen and ("vor " .. ago(now - d.last_seen)) or "",
    }
    if type(d.pos) == "table" then parts[#parts + 1] = ("%s %s %s"):format(tostring(d.pos.x), tostring(d.pos.y), tostring(d.pos.z)) end
    if d.fuel then parts[#parts + 1] = "Fuel " .. tostring(d.fuel) end
    if d.job then parts[#parts + 1] = tostring(d.job) end
    local mail = self.node:pending(d.id)
    if mail > 0 then parts[#parts + 1] = mail .. " Post" end
    lines[#lines + 1] = table.concat(parts, "  ")
  end
  return lines
end

return M
