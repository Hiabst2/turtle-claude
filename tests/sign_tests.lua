-- Tests fuer die Signatur von TurtleMQ (P2.1), werden von tests/run.lua geladen.
local sim = require("net")
local SECRET = "geheim123"

local function signedNet(o)
  local net = sim.new(o)
  local function node(id, extra)
    extra = extra or {}
    if extra.secret == nil then extra.secret = SECRET end
    return net.node(id, extra)
  end
  return net, node
end

local function inbox(n)
  local got = {}
  n:process(function(m) got[#got + 1] = m end)
  return got
end

test("Signatur: signierte Nachricht kommt an", function()
  local _, node = signedNet()
  local a, b = node(1), node(2)
  a:send(2, "t", { x = 1, liste = { 3, 2, 1 }, text = "äö" })
  local r = a:flush()
  eq(r.acked, 1, "ACK (selbst signiert) akzeptiert")
  local got = inbox(b)
  eq(#got, 1) eq(got[1].payload.liste[2], 2)
  eq(b.rejected, 0)
end)

test("Signatur: unsigniert, veraendert oder falscher Schluessel -> verworfen", function()
  local _, node = signedNet()
  local b = node(2)
  local a = require("mq").new({ id = 1, dir = "/n1x/.mq", now = sim.now, secret = SECRET })
  local good = a:sign(a:make(2, "t", { x = 1 }))

  local unsigned = {}
  for k, v in pairs(good) do unsigned[k] = v end
  unsigned.sig = nil
  eq(b:handle(unsigned), "rejected", "ohne Signatur")

  local changed = {}
  for k, v in pairs(good) do changed[k] = v end
  changed.payload = { x = 999 }
  eq(b:handle(changed), "rejected", "Inhalt veraendert")

  local fake = require("mq").new({ id = 1, dir = "/n1y/.mq", now = sim.now, secret = "falsch" })
  eq(b:handle(fake:sign(fake:make(2, "t", { x = 1 }))), "rejected", "falscher Schluessel")

  eq(b:handle(good), "new", "die echte geht")
  eq(b.rejected, 3) eq(b.lastRejected, 1)
end)

test("Signatur: gefaelschtes ACK loescht nichts aus der Outbox", function()
  local _, node = signedNet({ loss = 1 }) -- nichts kommt durch, wir spielen das ACK selbst ein
  local a = node(1)
  local id = a:send(2, "t", {})
  local forged = { v = 1, id = "2:1:1", ts = sim.clock, source = 2, target = 1, topic = "mq.ack", reply_to = id }
  eq(a:handle(forged), "rejected")
  eq(a:pending(), 1, "Nachricht noch da")
  local evil = require("mq").new({ id = 2, dir = "/n2x/.mq", now = sim.now, secret = "falsch" })
  eq(a:handle(evil:sign(forged)), "rejected")
  eq(a:pending(), 1)
end)

test("Signatur: Weiterleiten ueber das Gateway bleibt gueltig", function()
  local net, node = signedNet()
  local gw = node(100, { names = { "gateway" }, accept = function() return true end })
  local b = require("broker").new(gw, { dir = "/gws" })
  local turtle, tail = node(5), node(7)
  tail:subscribe({ "worker.*" })
  tail:flush()
  b:step(0)
  turtle.link.down = true
  local service = node(6)
  service:send(5, "job.assign", { area = 1 }) -- ans Postfach
  service:flush()
  b:step(0)
  turtle.link.down = false
  turtle:send("gateway", "worker.heartbeat", { fuel = 5 })
  turtle:flush()
  b:step(0)
  local t = inbox(turtle)
  local found = false
  for _, m in ipairs(t) do if m.topic == "job.assign" then found = true end end
  assert(found, "Post ueber das Gateway nicht angekommen")
  local beats = 0
  for _, m in ipairs(inbox(tail)) do if m.topic == "worker.heartbeat" then beats = beats + 1 end end
  eq(beats, 1, "Abo-Kopie angekommen")
  eq(turtle.rejected + tail.rejected + gw.rejected, 0, "nichts abgelehnt")
end)

test("Signatur: Geraet mit falschem Geheimnis kommt nicht durch, Gateway zaehlt es", function()
  local net, node = signedNet()
  local gw = node(100, { names = { "gateway" }, accept = function() return true end })
  local b = require("broker").new(gw, { dir = "/gwf" })
  local wrong = node(9, { secret = "falsch" })
  wrong:send("gateway", "worker.heartbeat", { fuel = 1 })
  local r = wrong:flush()
  b:step(0)
  eq(r.acked, 0)
  eq(b.state.devices[9], nil, "nicht beim Gateway angemeldet")
  assert(gw.rejected >= 1, "nicht gezaehlt") eq(gw.lastRejected, 9)
end)

test("Signatur: ohne Geheimnis wie bisher (abwaertskompatibel)", function()
  local net = sim.new()
  local a = net.node(1, { secret = false })
  local b = net.node(2, { secret = false })
  a.secret, b.secret = nil, nil
  a:send(2, "t", {})
  eq(a:flush().acked, 1)
  eq(#inbox(b), 1)
end)

test("Signatur: 100 signierte Nachrichten ueber ein schlechtes Netz, genau einmal", function()
  local _, node = signedNet({ seed = 11, loss = 0.3, dup = 0.2, reorder = 0.3 })
  local a, b = node(1), node(2)
  for i = 1, 100 do a:send(2, "t", { i = i }) end
  local got, doubles = {}, 0
  for _ = 1, 60 do
    sim.advance(61000)
    a:flush()
    b:process(function(m)
      if got[m.payload.i] then doubles = doubles + 1 end
      got[m.payload.i] = true
    end)
    if a:pending() == 0 then break end
  end
  b:process(function(m) got[m.payload.i] = true end)
  eq(doubles, 0)
  for i = 1, 100 do assert(got[i], "verloren " .. i) end
  eq(b.rejected, 0)
end)
