-- mq.lua - TurtleMQ: Nachrichten zwischen Geraeten, die nicht verloren gehen
--
-- Zustellung "at-least-once": jede Nachricht liegt bis zur Bestaetigung (ACK) in der Outbox und wird
-- wiederholt gesendet. Der Empfaenger speichert sie erst in seiner Inbox, schickt dann das ACK und
-- verarbeitet sie danach. Doppelt ankommende Nachrichten erkennt er an der id ("seen") und verarbeitet
-- sie nicht noch einmal. Siehe Whitepaper Abschnitt 4.
--
--   local node = mq.new({ link = mq.modemLink(modem), names = { "gateway" } })
--   node:send("gateway", "worker.status", { fuel = 1000 })
--   node:flush()                    -- Outbox senden, auf ACKs warten
--   node:poll(1)                    -- 1 s lang empfangen
--   node:process(function(msg) ... end)
--
-- Mehrere Knoten koennen im selben Programm laufen (Tests simulieren damit ein ganzes Netz).
--
-- Signatur (P2): ist "set mq.secret <text>" gesetzt (auf allen Geraeten gleich), traegt jedes Paket
-- in "sig" ein HMAC-SHA256 - auch ACKs und mq.done, sonst koennte ein gefaelschtes ACK Nachrichten
-- aus einer Outbox loeschen. Pakete ohne gueltige Signatur werden verworfen. Signiert ist alles
-- ausser target, hop und attempt: die aendern sich beim Weiterleiten durch das Gateway.
--
-- ACKs gelten pro Strecke: jedes gesendete Paket traegt in "hop" den Sender dieser Strecke, das ACK
-- geht an hop. Leitet das Gateway weiter, bestaetigt der Empfaenger also dem Gateway. Die id bleibt
-- dabei gleich, so erkennt der Empfaenger Doppelte auch ueber verschiedene Wege.

local store = require("store")
local crypto = require("crypto")

local M = {}

M.VERSION = 1
M.CHANNEL = 4242
M.ACK_TIMEOUT = 2 -- Sekunden, die flush() auf ACKs wartet
M.DEFAULT_TTL = 3600 -- Sekunden, danach wird eine Nachricht verworfen statt zugestellt
M.SEEN_MAX = 500 -- so viele zuletzt verarbeitete ids werden zum Erkennen von Doppelten gemerkt
M.MAX_TRIES = 3 -- Verarbeitungsversuche, danach landet eine Nachricht in dead/

local Node = {}
Node.__index = Node

-- Dateinamen duerfen in CC kein ":" enthalten
local function fileName(id)
  return (id:gsub("[^%w%-]", "_"))
end

local function shallowCopy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Node)
  self.id = opts.id or os.getComputerID()
  self.names = {}
  for _, n in ipairs(opts.names or {}) do self.names[n] = true end
  self.dir = opts.dir or "/.mq"
  self.link = opts.link
  self.now = opts.now or function() return os.epoch("utc") end
  self.accept = opts.accept -- optional: function(msg) -> true, wenn der Knoten auch fremde Ziele annimmt (Broker)
  local secret = opts.secret
  if secret == nil then secret = settings.get("mq.secret") end
  if secret == "" then secret = nil end
  self.secret = secret
  self.rejected = 0
  self.counter = 0
  for _, sub in ipairs({ "outbox", "inbox", "dead" }) do fs.makeDir(self.dir .. "/" .. sub) end
  local seen = store.load(self.dir .. "/seen")
  self.seen = { list = seen and seen.list or {} }
  self.seenSet = {}
  for _, id in ipairs(self.seen.list) do self.seenSet[id] = true end
  return self
end

-- Dateien -------------------------------------------------------------------

function Node:path(sub, id)
  return self.dir .. "/" .. sub .. "/" .. fileName(id)
end

local function remove(path)
  for _, suffix in ipairs({ "", ".bak", ".tmp" }) do
    if fs.exists(path .. suffix) then fs.delete(path .. suffix) end
  end
end

-- alle Nachrichten in outbox/inbox/dead, aelteste zuerst
function Node:list(sub)
  local dir = self.dir .. "/" .. sub
  local bases = {}
  for _, name in ipairs(fs.list(dir)) do bases[(name:gsub("%.bak$", ""):gsub("%.tmp$", ""))] = true end
  local msgs = {}
  for base in pairs(bases) do
    local msg = store.load(dir .. "/" .. base)
    if msg then msgs[#msgs + 1] = msg end
  end
  table.sort(msgs, function(a, b)
    if a.ts ~= b.ts then return a.ts < b.ts end
    if a.id ~= b.id then return a.id < b.id end
    return (a.key or "") < (b.key or "")
  end)
  return msgs
end

function Node:markSeen(id)
  if self.seenSet[id] then return end
  self.seenSet[id] = true
  local list = self.seen.list
  list[#list + 1] = id
  while #list > M.SEEN_MAX do
    self.seenSet[table.remove(list, 1)] = nil
  end
  store.save(self.dir .. "/seen", self.seen)
end

-- Signatur -------------------------------------------------------------------

-- eindeutige Textform eines Werts (Tabellen mit sortierten Schluesseln), Grundlage der Signatur
local function canon(v)
  local t = type(v)
  if t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return canon(a) < canon(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = canon(k) .. "=" .. canon(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return "s" .. #v .. ":" .. v
  elseif t == "number" then
    return "n" .. tostring(v)
  elseif t == "boolean" then
    return v and "T" or "F"
  end
  return "_"
end
M.canon = canon

local SIGNED = { "v", "id", "ts", "source", "topic", "payload", "ttl", "reply_to" }

local function signature(secret, packet)
  local parts = {}
  for _, k in ipairs(SIGNED) do parts[#parts + 1] = k .. "=" .. canon(packet[k]) end
  return crypto.hmac(secret, table.concat(parts, ";"))
end

function Node:sign(packet)
  if self.secret then packet.sig = signature(self.secret, packet) end
  return packet
end

function Node:verify(packet)
  if not self.secret then return true end
  return crypto.equal(packet.sig, signature(self.secret, packet))
end

-- Nachrichten bauen und senden ----------------------------------------------

function Node:newId()
  self.counter = self.counter + 1
  return ("%s:%d:%d"):format(tostring(self.id), self.now(), self.counter)
end

function Node:make(target, topic, payload, opts)
  opts = opts or {}
  -- streng steigend, damit die Reihenfolge eigener Nachrichten auch innerhalb einer Millisekunde stimmt
  -- (die Outbox sortiert nach ts; der Zaehler in der id wuerde als Text verglichen: "10" < "9")
  local ts = math.max(self.now(), (self.lastTs or 0) + 1)
  self.lastTs = ts
  return {
    v = M.VERSION,
    id = self:newId(),
    ts = ts,
    source = self.id,
    target = target,
    topic = topic,
    payload = payload,
    ttl = opts.ttl or M.DEFAULT_TTL,
    reply_to = opts.reply_to,
    attempt = 0,
  }
end

-- Legt die Nachricht in die Outbox. Gesendet wird beim naechsten flush().
function Node:send(target, topic, payload, opts)
  local msg = self:sign(self:make(target, topic, payload, opts))
  store.save(self:path("outbox", msg.id), msg)
  return msg.id
end

-- Legt eine fremde Nachricht (unveraenderte id) zum Weiterleiten an "to" in die Outbox.
-- Mehrere Kopien derselben Nachricht an verschiedene Empfaenger unterscheiden sich im key.
function Node:forward(msg, to)
  local copy = shallowCopy(msg)
  copy.target = to
  copy.key = msg.id .. "@" .. tostring(to)
  copy.attempt, copy.next, copy.tries, copy.error, copy.hop = 0, nil, nil, nil, nil
  store.save(self:path("outbox", copy.key), copy)
  return copy.key
end

-- Stellt eine Nachricht an einen Dienst auf diesem Computer zu, ohne Funk: direkt in die eigene Inbox
-- (persistent, mit Dedupe wie jede andere Nachricht). Fuer den Service-Host der Zentrale.
function Node:deliverLocal(target, topic, payload, opts)
  local msg = self:sign(self:make(target, topic, payload, opts))
  msg.tries = 0
  store.save(self:path("inbox", msg.id), msg)
  return msg.id
end

-- Entfernt Nachrichten aus der Outbox, fuer die filter(msg) true liefert (z.B. veraltete Heartbeats)
function Node:drop(filter)
  local n = 0
  for _, msg in ipairs(self:list("outbox")) do
    if filter(msg) then
      remove(self:path("outbox", msg.key or msg.id))
      n = n + 1
    end
  end
  return n
end

-- Nachrichten in der Outbox, optional nur die an ein bestimmtes Ziel
function Node:pending(target)
  local n = 0
  for _, msg in ipairs(self:list("outbox")) do
    if target == nil or msg.target == target then n = n + 1 end
  end
  return n
end

local function backoff(attempt)
  return math.min(2 ^ attempt, 60) * 1000
end

-- Sendet alle faelligen Nachrichten der Outbox und wartet bis zu ACK_TIMEOUT auf die ACKs.
-- Nebenbei ankommende Nachrichten werden ganz normal angenommen.
-- opts.force: auch Nachrichten senden, deren Wartezeit (Backoff) noch nicht um ist (Sync-Fenster)
-- opts.target: nur Nachrichten an dieses Ziel (Gateway: Postfach eines Geraets, das sich gerade meldet)
-- opts.skip(msg): true = diesmal nicht senden (Gateway: Sync-Geraete hoeren nur im Sync-Fenster zu).
--   Abgelaufene Nachrichten werden trotzdem verworfen.
function Node:flush(opts)
  opts = opts or {}
  local result = { sent = 0, acked = 0, dropped = {} }
  if not self.link then return result end
  local now = self.now()
  self.waiting = {}
  for _, msg in ipairs(self:list("outbox")) do
    local file = self:path("outbox", msg.key or msg.id)
    if opts.target ~= nil and msg.target ~= opts.target then
      -- anderes Ziel, diesmal nicht
    elseif now - msg.ts > msg.ttl * 1000 then
      remove(file)
      result.dropped[#result.dropped + 1] = msg
    elseif opts.skip and opts.skip(msg) then
      -- wartet auf den naechsten Kontakt
    elseif opts.force or not msg.next or msg.next <= now then
      msg.attempt = (msg.attempt or 0) + 1
      msg.next = now + backoff(msg.attempt)
      store.save(file, msg)
      local packet = shallowCopy(msg)
      packet.next, packet.key = nil, nil
      packet.hop = self.id
      self.link.transmit(packet)
      self.waiting[msg.key or msg.id] = true
      result.sent = result.sent + 1
    end
  end

  local deadline = self.now() + M.ACK_TIMEOUT * 1000
  local before = self.acked or 0
  while next(self.waiting) do
    local left = (deadline - self.now()) / 1000
    if left <= 0 then break end
    local packet = self.link.receive(left)
    if not packet then break end
    self:handle(packet)
  end
  self.waiting = nil
  result.acked = (self.acked or 0) - before
  return result
end

-- Empfangen ------------------------------------------------------------------

function Node:wants(msg)
  local t = msg.target
  if t == "*" or t == self.id or self.names[t] then return true end
  return self.accept ~= nil and self.accept(msg) == true
end

function Node:ack(msg)
  self.link.transmit(self:sign({
    v = M.VERSION,
    id = self:newId(),
    ts = self.now(),
    source = self.id,
    target = msg.hop or msg.source, -- ACK gilt fuer diese Strecke
    topic = "mq.ack",
    reply_to = msg.id,
  }))
end

-- Kurzer Hinweis ohne Speichern und ohne ACK (z.B. "mq.done": Gateway hat alles fuer dich geschickt)
function Node:hint(target, topic)
  if not self.link then return end
  self.link.transmit(self:sign({ v = M.VERSION, id = self:newId(), ts = self.now(), source = self.id,
    target = target, topic = topic }))
end

-- Verarbeitet ein empfangenes Paket.
-- Rueckgabe: "ack", "new", "dup", "expired", "done", "rejected" (Signatur) oder "ignored".
function Node:handle(packet)
  if type(packet) ~= "table" or packet.v ~= M.VERSION or type(packet.id) ~= "string" then return "ignored" end

  if not self:verify(packet) then
    -- nur zaehlen, wenn das Paket uns betrifft; fremder Funkverkehr ohne Signatur ist kein Angriff auf uns
    if packet.target == self.id or self:wants(packet) then
      self.rejected = self.rejected + 1
      self.lastRejected = packet.source
    end
    return "rejected"
  end

  if packet.topic == "mq.done" then
    if packet.target == self.id then self.done = true end
    return "done"
  end

  if packet.topic == "mq.ack" then
    if packet.target ~= self.id or type(packet.reply_to) ~= "string" then return "ignored" end
    for _, key in ipairs({ packet.reply_to, packet.reply_to .. "@" .. tostring(packet.source) }) do
      local path = self:path("outbox", key)
      if fs.exists(path) or fs.exists(path .. ".bak") then
        remove(path)
        self.acked = (self.acked or 0) + 1
      end
      if self.waiting then self.waiting[key] = nil end
    end
    return "ack"
  end

  if not self:wants(packet) then return "ignored" end

  -- abgelaufen: bestaetigen, damit der Sender aufhoert, aber nicht mehr zustellen
  if self.now() - (packet.ts or 0) > (packet.ttl or M.DEFAULT_TTL) * 1000 then
    self:ack(packet)
    return "expired"
  end

  local path = self:path("inbox", packet.id)
  if self.seenSet[packet.id] or fs.exists(path) or fs.exists(path .. ".bak") then
    self:ack(packet) -- das erste ACK ging wohl verloren
    return "dup"
  end
  local msg = shallowCopy(packet)
  msg.tries = 0
  store.save(path, msg) -- erst speichern ...
  self:ack(packet) -- ... dann bestaetigen: ein Absturz dazwischen verliert nichts
  return "new"
end

-- Empfaengt bis zu timeout Sekunden lang (bzw. bis nichts mehr kommt). Gibt die Anzahl neuer Nachrichten zurueck.
-- opts.quiet: nach dem ersten Paket nur noch so lange auf weitere warten (Sekunden), dann zurueck
-- opts.untilDone: aufhoeren, sobald das Gateway "mq.done" schickt (Sync-Fenster der Turtle).
--   self.done vorher selbst zuruecksetzen (vor dem flush), denn das Signal kann schon waehrend
--   des Wartens auf die ACKs ankommen.
function Node:poll(timeout, opts)
  if not self.link then return 0 end
  local quiet = opts and opts.quiet
  local untilDone = opts and opts.untilDone
  local deadline = self.now() + (timeout or 0) * 1000
  local new, got = 0, false
  while not (untilDone and self.done) do
    local left = math.max(0, (deadline - self.now()) / 1000)
    if got and quiet then left = math.min(left, quiet) end
    local packet = self.link.receive(left)
    if not packet then break end
    got = true
    if self:handle(packet) == "new" then new = new + 1 end
  end
  return new
end

-- Ruft handler(msg) fuer jede Nachricht der Inbox auf. Wirft der handler einen Fehler, wird es spaeter
-- erneut versucht; nach MAX_TRIES Fehlversuchen landet die Nachricht in dead/.
function Node:process(handler)
  local done = 0
  for _, msg in ipairs(self:list("inbox")) do
    local path = self:path("inbox", msg.id)
    local ok, err = pcall(handler, msg)
    if ok then
      self:markSeen(msg.id)
      remove(path)
      done = done + 1
    else
      msg.tries = (msg.tries or 0) + 1
      msg.error = tostring(err)
      if msg.tries >= M.MAX_TRIES then
        store.save(self:path("dead", msg.id), msg)
        self:markSeen(msg.id) -- auch erneut zugestellte Kopien nicht wieder versuchen
        remove(path)
      else
        store.save(path, msg)
      end
    end
  end
  return done
end

-- Am Gateway anmelden ------------------------------------------------------------

-- Meldet Namen (z.B. "job") und Infos (label, role, ...) beim Gateway an
function Node:register(names, info)
  info = info or {}
  info.names = names
  return self:send("gateway", "mq.register", info)
end

-- Abonniert Topics: genauer Name, Praefix mit "*" (z.B. "worker.*") oder "*" fuer alles
function Node:subscribe(topics)
  return self:send("gateway", "mq.subscribe", { topics = topics })
end

-- Funk ueber ein Modem ---------------------------------------------------------

function M.modemLink(modem, channel)
  channel = channel or settings.get("mq.channel", M.CHANNEL)
  modem.open(channel)
  return {
    transmit = function(packet) modem.transmit(channel, channel, packet) end,
    receive = function(timeout)
      local timer = os.startTimer(timeout or 0)
      while true do
        local event, a, ch, _, message = os.pullEvent()
        if event == "modem_message" and ch == channel and type(message) == "table" and message.v then
          os.cancelTimer(timer)
          return message
        elseif event == "timer" and a == timer then
          return nil
        end
      end
    end,
    close = function() modem.close(channel) end,
  }
end

return M
