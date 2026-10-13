-- Tests fuer TurtleMQ (P1.1), werden von tests/run.lua geladen.
-- Ein simuliertes Funknetz verliert, verdoppelt und vertauscht Pakete; die Tests pruefen,
-- dass trotzdem jede Nachricht genau einmal verarbeitet wird.

local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

-- reproduzierbarer Zufall
local function rng(seed)
  local s = seed
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

-- Netz mit einstellbarer Stoerung. Jeder Knoten bekommt einen link; receive() laesst zuerst alle
-- anderen Knoten ihre Warteschlange abarbeiten (die schicken dabei ACKs) und liefert dann das
-- naechste Paket fuer diesen Knoten.
local function newNet(o)
  o = o or {}
  local rnd = rng(o.seed or 42)
  local net = { links = {}, transmitted = 0 }
  function net.link()
    local link = { queue = {} }
    function link.transmit(packet)
      net.transmitted = net.transmitted + 1
      for _, other in ipairs(net.links) do
        if other ~= link and rnd() >= (o.loss or 0) then
          for _ = 1, (rnd() < (o.dup or 0)) and 2 or 1 do
            if rnd() < (o.reorder or 0) then
              table.insert(other.queue, 1, copy(packet))
            else
              other.queue[#other.queue + 1] = copy(packet)
            end
          end
        end
      end
    end
    function link.receive()
      net.pump(link)
      return table.remove(link.queue, 1)
    end
    net.links[#net.links + 1] = link
    return link
  end
  -- alle anderen Knoten nehmen an, was bei ihnen angekommen ist
  function net.pump(except)
    for _, other in ipairs(net.links) do
      if other ~= except and other.node then
        while #other.queue > 0 do other.node:handle(table.remove(other.queue, 1)) end
      end
    end
  end
  return net
end

local clock = 1000000
local function now() return clock end

local function node(net, id, extra)
  local link = net.link()
  local o = { id = id, dir = "/n" .. id .. "/.mq", link = link, now = now }
  for k, v in pairs(extra or {}) do o[k] = v end
  local n = require("mq").new(o)
  link.node = n
  return n
end

test("MQ: Nachricht kommt an, ACK leert die Outbox", function()
  local net = newNet()
  local a, b = node(net, 1), node(net, 2)
  local id = a:send(2, "test.hallo", { text = "hi" })
  eq(a:pending(), 1)
  local r = a:flush()
  eq(r.sent, 1) eq(r.acked, 1)
  eq(a:pending(), 0, "Outbox nach ACK")
  local got = {}
  eq(b:process(function(m) got[#got + 1] = m end), 1)
  eq(got[1].id, id) eq(got[1].payload.text, "hi") eq(got[1].topic, "test.hallo") eq(got[1].source, 1)
  eq(#b:list("inbox"), 0, "Inbox nach Verarbeitung")
end)

test("MQ: 100 Nachrichten ueber ein schlechtes Netz kommen genau einmal an", function()
  local net = newNet({ seed = 7, loss = 0.3, dup = 0.2, reorder = 0.3 })
  local a, b = node(net, 1), node(net, 2)
  local sent = {}
  for i = 1, 100 do sent[a:send(2, "test.n", { i = i })] = i end
  -- Doppelte zaehlen statt im Handler zu werfen: process() faengt Handler-Fehler ab
  local seen, count, doubles = {}, 0, 0
  local rounds = 0
  while (a:pending() > 0 or #b:list("inbox") > 0) and rounds < 60 do
    rounds = rounds + 1
    clock = clock + 61000 -- Backoff ist abgelaufen
    a:flush()
    net.pump()
    b:process(function(m)
      if seen[m.id] then doubles = doubles + 1 end
      seen[m.id] = true
      count = count + 1
    end)
  end
  eq(doubles, 0, "doppelt verarbeitet")
  eq(count, 100, "verarbeitet")
  eq(a:pending(), 0, "Outbox leer")
  for id in pairs(sent) do assert(seen[id], "verloren: " .. id) end
  assert(rounds > 1, "das Netz sollte Wiederholungen noetig machen")
end)

test("MQ: Haertetest - 20 Stoermuster, in beide Richtungen gleichzeitig", function()
  for seed = 1, 20 do
    fs.delete("/n1") fs.delete("/n2")
    local net = newNet({ seed = seed, loss = 0.5, dup = 0.3, reorder = 0.5 })
    local a, b = node(net, 1), node(net, 2)
    for i = 1, 15 do a:send(2, "t", { i = i }) b:send(1, "t", { i = i }) end
    local gotA, gotB, doubles = {}, {}, 0
    local function collect(into)
      return function(m)
        if into[m.payload.i] then doubles = doubles + 1 end
        into[m.payload.i] = true
      end
    end
    for _ = 1, 80 do
      clock = clock + 61000
      a:flush() b:flush()
      a:process(collect(gotA)) b:process(collect(gotB))
      if a:pending() == 0 and b:pending() == 0 then break end
    end
    net.pump()
    a:process(collect(gotA)) b:process(collect(gotB))
    eq(doubles, 0, ("seed %d: doppelt verarbeitet"):format(seed))
    for i = 1, 15 do
      assert(gotA[i] and gotB[i], ("seed %d: Nachricht %d verloren"):format(seed, i))
    end
  end
end)

test("MQ: modemLink nimmt nur passende Modem-Nachrichten und hat ein Timeout", function()
  local opened, sent = nil, {}
  local modem = {
    open = function(ch) opened = ch end,
    transmit = function(ch, reply, msg) sent[#sent + 1] = { ch, reply, msg } end,
    close = function() end,
  }
  local link = require("mq").modemLink(modem)
  eq(opened, 4242)
  link.transmit({ v = 1, id = "a" })
  eq(sent[1][1], 4242) eq(sent[1][3].id, "a")

  local co = coroutine.create(function() return link.receive(1) end)
  coroutine.resume(co)
  coroutine.resume(co, "chat", "x", "y")
  coroutine.resume(co, "modem_message", "left", 9999, 9999, { v = 1, id = "falscher Kanal" })
  coroutine.resume(co, "modem_message", "left", 4242, 4242, "kein Paket")
  local _, packet = coroutine.resume(co, "modem_message", "left", 4242, 4242, { v = 1, id = "richtig" })
  eq(packet.id, "richtig")

  co = coroutine.create(function() return link.receive(1) end)
  coroutine.resume(co)
  local timer = require("cc").timers
  local ok, res = coroutine.resume(co, "timer", timer)
  eq(ok, true) eq(res, nil) eq(coroutine.status(co), "dead")
end)

test("MQ: Absturz nach dem Speichern verliert nichts und verarbeitet nichts doppelt", function()
  local net = newNet()
  local a, b = node(net, 1), node(net, 2)
  local id = a:send(2, "test.x", {})
  a:flush()
  -- b hat gespeichert und bestaetigt, stuerzt aber vor process() ab: neuer Start, gleicher Ordner
  local b2 = require("mq").new({ id = 2, dir = "/n2/.mq", link = b.link, now = now })
  b.link.node = b2
  local n = 0
  b2:process(function() n = n + 1 end)
  eq(n, 1)
  -- dieselbe Nachricht kommt noch einmal (z.B. weil das ACK verloren ging)
  eq(b2:handle({ v = 1, id = id, ts = clock, source = 1, target = 2, topic = "test.x", ttl = 3600 }), "dup")
  b2:process(function() n = n + 1 end)
  eq(n, 1, "nicht noch einmal verarbeitet")
end)

test("MQ: gesehene ids ueberleben einen Neustart", function()
  local net = newNet()
  local b = node(net, 2)
  local pkt = { v = 1, id = "1:5:1", ts = clock, source = 1, target = 2, topic = "t", ttl = 3600 }
  eq(b:handle(pkt), "new")
  b:process(function() end)
  local b2 = require("mq").new({ id = 2, dir = "/n2/.mq", link = b.link, now = now })
  eq(b2:handle(pkt), "dup")
end)

test("MQ: abgelaufene Nachrichten werden verworfen und gemeldet", function()
  local net = newNet({ loss = 1 }) -- nichts kommt an
  local a = node(net, 1)
  local id = a:send(2, "t", {}, { ttl = 10 })
  a:flush()
  eq(a:pending(), 1, "noch nicht abgelaufen")
  clock = clock + 11000
  local r = a:flush()
  eq(#r.dropped, 1) eq(r.dropped[1].id, id)
  eq(a:pending(), 0)
end)

test("MQ: Backoff - nicht bei jedem flush neu senden, im Sync-Fenster (force) schon", function()
  local net = newNet({ loss = 1 })
  local a = node(net, 1)
  a:send(2, "t", {})
  eq(a:flush().sent, 1)
  eq(a:flush().sent, 0, "Wartezeit laeuft noch")
  eq(a:flush({ force = true }).sent, 1)
end)

test("MQ: Fehler im Handler -> spaeter erneut, nach 3 Versuchen dead letter", function()
  local net = newNet()
  local b = node(net, 2)
  local pkt = { v = 1, id = "1:9:1", ts = clock, source = 1, target = 2, topic = "t", ttl = 3600 }
  b:handle(pkt)
  local tries = 0
  local function bad() tries = tries + 1 error("kaputt") end
  b:process(bad)
  eq(#b:list("inbox"), 1, "nach 1 Fehler noch da")
  b:process(bad)
  b:process(bad)
  eq(tries, 3)
  eq(#b:list("inbox"), 0)
  local dead = b:list("dead")
  eq(#dead, 1) assert(dead[1].error:find("kaputt"))
  eq(b:handle(pkt), "dup", "dead letter wird nicht wieder angenommen")
end)

test("MQ: fremde Ziele werden ignoriert, Namen und Broadcast angenommen", function()
  local net = newNet()
  local b = node(net, 2, { names = { "gateway" } })
  local function pkt(target, n)
    return { v = 1, id = "1:1:" .. n, ts = clock, source = 1, target = target, topic = "t", ttl = 3600 }
  end
  eq(b:handle(pkt(3, 1)), "ignored")
  eq(b:handle(pkt("gateway", 2)), "new")
  eq(b:handle(pkt("*", 3)), "new")
  eq(b:handle({ v = 99, id = "x" }), "ignored", "fremde Protokollversion")
  local broker = node(net, 4, { accept = function() return true end })
  eq(broker:handle(pkt(99, 4)), "new", "Broker nimmt alles an")
end)

test("MQ: Dateinamen enthalten keine Doppelpunkte", function()
  local net = newNet({ loss = 1 })
  local a = node(net, 1)
  a:send(2, "t", {})
  for _, name in ipairs(fs.list("/n1/.mq/outbox")) do assert(not name:find(":"), name) end
end)

test("MQ: seen-Liste ist begrenzt", function()
  local mq = require("mq")
  local net = newNet()
  local b = node(net, 2)
  local old = mq.SEEN_MAX
  mq.SEEN_MAX = 5
  for i = 1, 8 do b:markSeen("id" .. i) end
  mq.SEEN_MAX = old
  eq(#b.seen.list, 5)
  eq(b.seenSet["id1"], nil) eq(b.seenSet["id8"], true)
end)
