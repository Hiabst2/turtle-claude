-- jobsvc.lua - Job-Dienst der Zentrale (Whitepaper 6, 6.1)
--
-- Auftraege: created -> assigned -> accepted -> running -> complete | failed | cancelled
--   * Zuteilung im Pull-Verfahren: ein Worker meldet sich mit worker.idle (Rolle, Ausruestung, Position,
--     Fuel) und bekommt den wichtigsten Auftrag, den er erledigen kann.
--   * Lease: ein Auftrag gehoert einem Worker nur auf Zeit. job.accept und job.progress verlaengern sie.
--     Laeuft sie ab, geht der Auftrag zurueck in die Warteschlange (nach MAX_ATTEMPTS: failed).
--   * Epoche: jede Zuteilung zaehlt job.epoch hoch. Meldungen mit alter Epoche stammen von einem Worker,
--     dem der Auftrag nicht mehr gehoert: er bekommt job.revoke und bricht ab.
--   * Bereichsreservierung: zwei laufende Auftraege haben nie ueberlappende Bereiche.
--   * Idempotent: doppelt zugestellte Nachrichten (TurtleMQ: at-least-once) aendern nichts doppelt.
--
-- Der Dienst kennt keinen Funk: er bekommt Nachrichten ueber handle(msg) und schickt ueber host.send.

local store = require("store")
local cost = require("cost")

local M = {}

M.LEASE = 300 -- Sekunden (5 x Sync-Intervall)
M.MAX_ATTEMPTS = 3
M.TYPES = { orehunt = true, stripmine = true, tunnel = true, ["goto"] = true, gohome = true }
-- Mining-Auftraege nur mit Kiste als Zwischenspeicher, Erzjagd zusaetzlich mit Geo Scanner
M.REQUIRES = { orehunt = { "geo_scanner", "chest" }, stripmine = { "chest" }, tunnel = { "chest" } }

local ACTIVE = { assigned = true, accepted = true, running = true }
local FINAL = { complete = true, failed = true, cancelled = true }

local Service = {}
Service.__index = Service

function M.new(host, opts)
  opts = opts or {}
  local self = setmetatable({}, Service)
  self.host = host
  self.dir = opts.dir or "/.central"
  fs.makeDir(self.dir)
  self.file = self.dir .. "/jobs"
  self.state = store.load(self.file) or { jobs = {}, next = 1 }
  self.log = {}
  return self
end

function Service:save() store.save(self.file, self.state) end
function Service:now() return self.host.now() end

function Service:note(text)
  table.insert(self.log, 1, text)
  while #self.log > 20 do table.remove(self.log) end
end

local function normArea(a)
  if type(a) ~= "table" then return nil end
  local v = { tonumber(a.x1), tonumber(a.y1), tonumber(a.z1), tonumber(a.x2), tonumber(a.y2), tonumber(a.z2) }
  for i = 1, 6 do if not v[i] then return nil end end
  return {
    x1 = math.min(v[1], v[4]), x2 = math.max(v[1], v[4]),
    y1 = math.min(v[2], v[5]), y2 = math.max(v[2], v[5]),
    z1 = math.min(v[3], v[6]), z2 = math.max(v[3], v[6]),
  }
end

local function overlap(a, b)
  return a ~= nil and b ~= nil and a.x1 <= b.x2 and b.x1 <= a.x2 and a.y1 <= b.y2 and b.y1 <= a.y2
    and a.z1 <= b.z2 and b.z1 <= a.z2
end

-- Auftrag anlegen. p = { type, params, area, priority, role, requires }
function Service:create(p, by)
  if not M.TYPES[p.type] then return nil, "unbekannter Auftragstyp: " .. tostring(p.type) end
  if p.area ~= nil and not normArea(p.area) then return nil, "Bereich braucht x1 y1 z1 x2 y2 z2" end
  local now = self:now()
  local id = "J" .. self.state.next
  self.state.next = self.state.next + 1
  local job = {
    id = id, type = p.type, params = p.params or {}, area = normArea(p.area),
    priority = tonumber(p.priority) or 5, role = p.role or "miner",
    requires = p.requires or M.REQUIRES[p.type] or {},
    state = "created", attempts = 0, epoch = 0,
    created_by = by, created_at = now, updated_at = now,
  }
  self.state.jobs[id] = job
  self:save()
  self:note(("%s angelegt: %s"):format(id, job.type))
  return job
end

-- Warum kann dieser Worker den Auftrag nicht uebernehmen? nil = er kann.
-- Zweiter Rueckgabewert: benoetigtes Fuel, wenn es (nur) am Fuel scheitert.
function Service:explain(job, worker)
  if (worker.role or "miner") ~= job.role then
    return ("braucht Rolle %s (Turtle hat %s)"):format(job.role, tostring(worker.role))
  end
  local gear = type(worker.gear) == "table" and worker.gear or {}
  local missing = {}
  for _, need in ipairs(job.requires or {}) do
    if not gear[need] then missing[#missing + 1] = need end
  end
  if #missing > 0 then return "fehlt " .. table.concat(missing, ", ") end
  -- genug Fuel fuer Anfahrt, Arbeit und den Weg zum Lager? (gleiche Formel wie Turtle und Path-Dienst)
  local need = cost.need(job, worker, tonumber(worker.travel_y))
  if tonumber(worker.fuel) and tonumber(worker.fuel) < need then
    return ("zu wenig Fuel (hat %d, braucht %d)"):format(worker.fuel, need), need
  end
  if not self:areaFree(job) then return "Bereich gerade von einem anderen Auftrag belegt" end
  return nil
end

function Service:canDo(job, worker)
  local reason = self:explain(job, worker)
  return reason == nil or reason == "Bereich gerade von einem anderen Auftrag belegt"
end

function Service:areaFree(job)
  if not job.area then return true end
  for _, other in pairs(self.state.jobs) do
    if other ~= job and ACTIVE[other.state] and overlap(job.area, other.area) then return false end
  end
  return true
end

-- wichtigster Auftrag, den dieser Worker jetzt erledigen kann
function Service:pick(worker)
  local list = {}
  for _, job in pairs(self.state.jobs) do
    if job.state == "created" and self:canDo(job, worker) and self:areaFree(job) then list[#list + 1] = job end
  end
  table.sort(list, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    if a.created_at ~= b.created_at then return a.created_at < b.created_at end
    return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2))
  end)
  return list[1]
end

function Service:assign(job, workerId)
  job.state, job.worker = "assigned", workerId
  job.epoch = job.epoch + 1
  job.lease_until = self:now() + M.LEASE * 1000
  job.updated_at = self:now()
  self.host.send(workerId, "job.assign", {
    id = job.id, epoch = job.epoch, type = job.type, params = job.params, area = job.area,
    requires = job.requires,
  })
  self:note(("%s -> #%s (Epoche %d)"):format(job.id, tostring(workerId), job.epoch))
end

-- Auftrag zurueck in die Warteschlange oder nach zu vielen Versuchen aufgeben
function Service:requeue(job, reason, retry)
  job.attempts = job.attempts + 1
  job.reason = reason
  job.worker, job.lease_until = nil, nil
  job.updated_at = self:now()
  if retry ~= false and job.attempts < M.MAX_ATTEMPTS then
    job.state = "created"
    self:note(("%s zurueck in die Warteschlange: %s"):format(job.id, tostring(reason)))
  else
    job.state = "failed"
    self:note(("%s fehlgeschlagen: %s"):format(job.id, tostring(reason)))
  end
end

-- Auftrag abbrechen; ein laufender Worker bekommt job.cancel und hoert auf
function Service:cancel(id)
  local job = self.state.jobs[id]
  if not job then return { error = "unbekannter Auftrag " .. tostring(id) } end
  if not FINAL[job.state] then
    if ACTIVE[job.state] and job.worker then
      self.host.send(job.worker, "job.cancel", { id = job.id, epoch = job.epoch })
    end
    job.state, job.updated_at = "cancelled", self:now()
    self:note(job.id .. " abgebrochen")
    self:save()
  end
  return { id = job.id, state = job.state }
end

function Service:summary(job)
  return {
    id = job.id, type = job.type, state = job.state, worker = job.worker, priority = job.priority,
    area = job.area, progress = job.progress, result = job.result, reason = job.reason,
    attempts = job.attempts, params = job.params,
  }
end

function Service:handle(msg)
  local p = type(msg.payload) == "table" and msg.payload or {}
  local topic = msg.topic
  local now = self:now()

  if topic == "job.create" then
    local job, err = self:create(p, msg.source)
    self.host.send(msg.source, "job.created", job and { id = job.id } or { error = err }, { reply_to = msg.id })

  elseif topic == "job.cancel" then
    self.host.send(msg.source, "job.cancelled", self:cancel(p.id), { reply_to = msg.id })

  elseif topic == "job.list" then
    local list = {}
    for _, job in pairs(self.state.jobs) do
      if p.all or not FINAL[job.state] or (now - job.updated_at) < 3600 * 1000 then
        list[#list + 1] = self:summary(job)
      end
    end
    table.sort(list, function(a, b) return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2)) end)
    self.host.send(msg.source, "job.list.reply", { jobs = list }, { reply_to = msg.id })

  elseif topic == "worker.idle" then
    -- Der Worker hat nichts zu tun. Hatte er einen Auftrag schon angenommen, ist der verloren
    -- (z.B. Neustart ohne Fortsetzen). Ist er nur zugeteilt, ist die Zuteilung wohl noch unterwegs:
    -- Turtles bekommen Post erst beim naechsten Sync. Dann nichts Neues zuteilen.
    local pending = false
    for _, job in pairs(self.state.jobs) do
      if job.worker == msg.source and (job.state == "accepted" or job.state == "running") then
        self:requeue(job, "Worker meldet sich frei, Auftrag verloren")
      elseif job.worker == msg.source and job.state == "assigned" then
        pending = true
      end
    end
    if not pending then
      local job = self:pick(p)
      if job then
        self:assign(job, msg.source)
      else
        -- nichts Passendes: dem Worker sagen, warum (und wie viel Fuel ihm fehlt), damit er handeln kann
        local reasons, needFuel = {}, nil
        for _, j in pairs(self.state.jobs) do
          if j.state == "created" then
            local why, need = self:explain(j, p)
            if why then
              reasons[#reasons + 1] = j.id .. ": " .. why
              if need and (not needFuel or need < needFuel) then needFuel = need end
            end
          end
        end
        if #reasons > 0 then
          table.sort(reasons)
          local text = table.concat(reasons, "; ")
          self.host.send(msg.source, "job.none", { reasons = text, need_fuel = needFuel }, { ttl = 120 })
          if self.lastWhy ~= text then
            self.lastWhy = text
            self:note(("#%s bekommt nichts: %s"):format(tostring(msg.source), text))
          end
        end
      end
    end

  elseif topic == "job.accept" or topic == "job.progress" or topic == "job.complete" or topic == "job.fail" then
    local job = self.state.jobs[p.id]
    local current = job and job.worker == msg.source and job.epoch == p.epoch and ACTIVE[job.state]
    if not current then
      -- doppelte Abschlussmeldung oder alter Besitzer: abschliessende Meldungen einfach ignorieren,
      -- laufende Arbeit dagegen stoppen
      if (topic == "job.accept" or topic == "job.progress") and not (job and FINAL[job.state] and job.worker == msg.source and job.epoch == p.epoch) then
        self.host.send(msg.source, "job.revoke", { id = p.id, epoch = p.epoch })
      end
      return true
    end
    job.updated_at = now
    if topic == "job.accept" or topic == "job.progress" then
      job.state = topic == "job.accept" and "accepted" or "running"
      if p.progress then job.progress = p.progress end
      job.lease_until = now + M.LEASE * 1000
    elseif topic == "job.complete" then
      job.state, job.result, job.lease_until = "complete", p.result, nil
      self:note(job.id .. " fertig")
    else
      self:requeue(job, p.reason or "Fehler beim Worker", p.retry)
    end
  else
    return false
  end
  self:save()
  return true
end

-- regelmaessig aufrufen: abgelaufene Leases einsammeln
function Service:tick()
  local now, changed = self:now(), false
  for _, job in pairs(self.state.jobs) do
    if ACTIVE[job.state] and job.lease_until and job.lease_until < now then
      self:requeue(job, ("Lease abgelaufen bei #%s"):format(tostring(job.worker)))
      changed = true
    end
  end
  if changed then self:save() end
end

-- Zeilen fuer den Bildschirm der Zentrale
function Service:statusLines()
  local list = {}
  for _, job in pairs(self.state.jobs) do
    if not FINAL[job.state] or (self:now() - job.updated_at) < 600 * 1000 then list[#list + 1] = job end
  end
  table.sort(list, function(a, b) return tonumber(a.id:sub(2)) < tonumber(b.id:sub(2)) end)
  local lines = {}
  for _, job in ipairs(list) do
    lines[#lines + 1] = ("%s %s  %s%s%s"):format(job.id, job.type, job.state,
      job.worker and ("  #" .. tostring(job.worker)) or "", job.progress and ("  " .. job.progress) or "")
  end
  return lines
end

return M
