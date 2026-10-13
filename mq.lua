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

local store = require("store")

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
    return a.id < b.id
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

-- Nachrichten bauen und senden ----------------------------------------------

function Node:newId()
  self.counter = self.counter + 1
  return ("%s:%d:%d"):format(tostring(self.id), self.now(), self.counter)
end

function Node:make(target, topic, payload, opts)
  opts = opts or {}
  return {
    v = M.VERSION,
    id = self:newId(),
    ts = self.now(),
    source = self.id,
    target = target,
    topic = topic,
    payload = payload,
    ttl = opts.ttl or M.DEFAULT_TTL,
    reply_to = opts.reply_to,
    attempt = 0,
    sig = nil, -- Signatur kommt in P2
  }
end

-- Legt die Nachricht in die Outbox. Gesendet wird beim naechsten flush().
function Node:send(target, topic, payload, opts)
  local msg = self:make(target, topic, payload, opts)
  store.save(self:path("outbox", msg.id), msg)
  return msg.id
end

function Node:pending()
  return #self:list("outbox")
end

local function backoff(attempt)
  return math.min(2 ^ attempt, 60) * 1000
end

-- Sendet alle faelligen Nachrichten der Outbox und wartet bis zu ACK_TIMEOUT auf die ACKs.
-- Nebenbei ankommende Nachrichten werden ganz normal angenommen.
-- opts.force: auch Nachrichten senden, deren Wartezeit (Backoff) noch nicht um ist (Sync-Fenster)
function Node:flush(opts)
  opts = opts or {}
  local result = { sent = 0, acked = 0, dropped = {} }
  if not self.link then return result end
  local now = self.now()
  self.waiting = {}
  for _, msg in ipairs(self:list("outbox")) do
    if now - msg.ts > msg.ttl * 1000 then
      remove(self:path("outbox", msg.id))
      result.dropped[#result.dropped + 1] = msg
    elseif opts.force or not msg.next or msg.next <= now then
      msg.attempt = (msg.attempt or 0) + 1
      msg.next = now + backoff(msg.attempt)
      store.save(self:path("outbox", msg.id), msg)
      local packet = shallowCopy(msg)
      packet.next = nil
      self.link.transmit(packet)
      self.waiting[msg.id] = true
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
  self.link.transmit({
    v = M.VERSION,
    id = self:newId(),
    ts = self.now(),
    source = self.id,
    target = msg.source,
    topic = "mq.ack",
    reply_to = msg.id,
  })
end

-- Verarbeitet ein empfangenes Paket. Rueckgabe: "ack", "new", "dup", "expired" oder "ignored".
function Node:handle(packet)
  if type(packet) ~= "table" or packet.v ~= M.VERSION or type(packet.id) ~= "string" then return "ignored" end

  if packet.topic == "mq.ack" then
    if packet.target ~= self.id or type(packet.reply_to) ~= "string" then return "ignored" end
    local path = self:path("outbox", packet.reply_to)
    if fs.exists(path) or fs.exists(path .. ".bak") then
      remove(path)
      self.acked = (self.acked or 0) + 1
    end
    if self.waiting then self.waiting[packet.reply_to] = nil end
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
function Node:poll(timeout)
  if not self.link then return 0 end
  local deadline = self.now() + (timeout or 0) * 1000
  local new = 0
  repeat
    local left = math.max(0, (deadline - self.now()) / 1000)
    local packet = self.link.receive(left)
    if not packet then break end
    if self:handle(packet) == "new" then new = new + 1 end
  until self.now() >= deadline and not packet
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
