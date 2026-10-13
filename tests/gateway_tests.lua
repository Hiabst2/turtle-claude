-- Tests fuer das Gateway (P1.2), werden von tests/run.lua geladen.
local sim = require("net")

local function setup(o)
  local net = sim.new(o)
  local gw = net.node(100, { names = { "gateway" }, accept = function() return true end })
  local b = require("broker").new(gw, { dir = "/gw" })
  return net, gw, b
end

-- eine Runde der Gateway-Schleife, derselbe Code wie im Spiel
local function gwStep(_, b) b:step(0) end

local function inbox(node)
  local got = {}
  node:process(function(m) got[#got + 1] = m end)
  return got
end

test("Gateway: Turtle ohne Modem bekommt ihre Post beim naechsten Melden", function()
  local net, gw, b = setup()
  local turtle, service = net.node(5), net.node(6)
  turtle.link.down = true
  service:send(5, "job.assign", { area = 1 })
  service:flush()
  eq(service:pending(), 0, "Gateway hat dem Absender bestaetigt")
  gwStep(gw, b)
  eq(gw:pending(5), 1, "liegt im Postfach")

  turtle.link.down = false
  turtle:send("gateway", "worker.heartbeat", { fuel = 900 })
  turtle:flush()
  gwStep(gw, b)
  local got = inbox(turtle)
  eq(#got, 1) eq(got[1].topic, "job.assign") eq(got[1].source, 6) eq(got[1].payload.area, 1)
  eq(gw:pending(5), 0, "Postfach leer")
end)

test("Gateway: Abonnenten bekommen passende Topics, andere nicht", function()
  local net, gw, b = setup()
  local turtle, tail = net.node(5), net.node(7)
  tail:subscribe({ "worker.*" })
  tail:flush()
  gwStep(gw, b)
  turtle:send("gateway", "worker.heartbeat", { fuel = 1 })
  turtle:send("gateway", "job.progress", { p = 1 })
  turtle:flush()
  gwStep(gw, b)
  local got = inbox(tail)
  eq(#got, 1) eq(got[1].topic, "worker.heartbeat")
end)

test("Gateway: Nachricht an einen Namen wartet, bis sich jemand so anmeldet", function()
  local net, gw, b = setup()
  local turtle = net.node(5)
  turtle:send("job", "job.create", { n = 1 })
  turtle:flush()
  gwStep(gw, b)
  eq(gw:pending("job"), 1, "wartet auf den Namen")
  local jobNode = net.node(8)
  jobNode:register({ "job" }, { role = "job" })
  jobNode:flush()
  gwStep(gw, b)
  local got = inbox(jobNode)
  -- dabei ist auch das eigene register-ACK; gezaehlt wird nur der Auftrag
  local jobs = 0
  for _, m in ipairs(got) do if m.topic == "job.create" then jobs = jobs + 1 end end
  eq(jobs, 1)
  eq(gw:pending("job"), 0) eq(gw:pending(8), 0)
end)

test("Gateway: Broadcast an alle bekannten Geraete ausser dem Absender", function()
  local net, gw, b = setup()
  local a, c, d = net.node(5), net.node(6), net.node(7)
  for _, n in ipairs({ a, c, d }) do
    n:send("gateway", "mq.fetch", {})
    n:flush()
  end
  gwStep(gw, b)
  c.link.down, d.link.down = true, true -- nur ueber das Gateway erreichbar
  a:send("*", "system.update", { v = 2 })
  a:flush()
  gwStep(gw, b)
  eq(gw:pending(5), 0, "nicht an den Absender")
  eq(gw:pending(6), 1) eq(gw:pending(7), 1)
end)

test("Gateway: Discovery liefert Namen und Geraete", function()
  local net, gw, b = setup()
  local j, s = net.node(8), net.node(6)
  j:register({ "job" }, { label = "Jobs" })
  j:flush()
  gwStep(gw, b)
  s:send("gateway", "system.discovery", {})
  s:flush()
  gwStep(gw, b)
  local got = inbox(s)
  eq(#got, 1) eq(got[1].topic, "system.directory") eq(got[1].payload.names.job, 8)
end)

test("Gateway: Status nach Whitepaper 5.3 (online, verspaetet, overdue, lost)", function()
  local net, gw, b = setup()
  local t = net.node(5)
  t:send("gateway", "worker.heartbeat", { label = "Hiabst", fuel = 4200, pos = { x = 725, y = 40, z = 630 },
    job = "orehunt 2/4", interval = 60 })
  t:flush()
  gwStep(gw, b)
  local line = b:statusLines()[1]
  assert(line:find("Hiabst") and line:find("online") and line:find("Fuel 4200") and line:find("725 40 630")
    and line:find("orehunt"), line)
  local d = b.state.devices[5]
  sim.advance(100 * 1000) eq(b:stateOf(d, sim.now()), "verspaetet")
  sim.advance(100 * 1000) eq(b:stateOf(d, sim.now()), "overdue")
  sim.advance(500 * 1000) eq(b:stateOf(d, sim.now()), "lost")
  d.offline_until = sim.now() + 1000
  eq(b:stateOf(d, sim.now()), "offline (angekuendigt)")
end)

test("Gateway: Zustand ueberlebt einen Neustart", function()
  local net, gw, b = setup()
  local t = net.node(5)
  t:register({ "miner1" }, { label = "M1" })
  t:subscribe({ "job.*" })
  t:flush()
  gwStep(gw, b)
  local b2 = require("broker").new(gw, { dir = "/gw" })
  eq(b2.state.names.miner1, 5)
  eq(b2.state.subs["job.*"][5], true)
  eq(b2.state.devices[5].label, "M1")
end)

test("Gateway: direkt und ueber das Gateway empfangen -> trotzdem nur einmal", function()
  local net, gw, b = setup()
  local a, c = net.node(5), net.node(6)
  a:send(6, "t", { x = 1 })
  a:flush() -- c hoert direkt mit, das Gateway auch
  gwStep(gw, b) -- und leitet es nochmal an c
  local got = inbox(c)
  eq(#got, 1)
  eq(gw:pending(6), 0, "c hat dem Gateway bestaetigt")
end)

test("Gateway: 30 Nachrichten an eine Turtle ueber ein schlechtes Netz", function()
  local net, gw, b = setup({ seed = 3, loss = 0.3, dup = 0.2, reorder = 0.3 })
  local turtle, service = net.node(5), net.node(6)
  turtle.link.down = true
  for i = 1, 30 do service:send(5, "t", { i = i }) end
  local got, doubles = {}, 0
  for _ = 1, 60 do
    sim.advance(61000)
    service:flush()
    gwStep(gw, b)
    turtle.link.down = false -- Sync-Fenster
    turtle:send("gateway", "mq.fetch", {})
    turtle:flush({ force = true })
    gwStep(gw, b)
    turtle:poll(0)
    turtle:process(function(m)
      if m.topic == "t" then
        if got[m.payload.i] then doubles = doubles + 1 end
        got[m.payload.i] = true
      end
    end)
    turtle.link.down = true
    if service:pending() == 0 and gw:pending(5) == 0 then break end
  end
  eq(doubles, 0, "doppelt")
  for i = 1, 30 do assert(got[i], "verloren: " .. i) end
end)
