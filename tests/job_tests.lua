-- Tests fuer Job-Dienst und Worker (P3.1), werden von tests/run.lua geladen.
local sim = require("net")
local cc = require("cc")

-- Gateway + Zentrale im simulierten Netz, Worker als einfache mq-Knoten (Teil A)
local function world(o)
  local net = sim.new(o)
  local gw = net.node(100, { names = { "gateway" }, accept = function() return true end })
  local broker = require("broker").new(gw, { dir = "/gw" })
  local centralNode = net.node(200, { dir = "/central/.mq" })
  local host = require("services").new(centralNode, { label = "Zentrale" })
  local jobs = require("jobsvc").new(host, { dir = "/central" })
  host.add("job", jobs)
  local map = require("mapsvc").new(host, { dir = "/central" })
  host.add("map", map)
  host.add("path", require("pathsvc").new(host))
  local w = { net = net, gw = gw, broker = broker, host = host, jobs = jobs, map = map }
  function w.step(n)
    for _ = 1, n or 3 do
      broker:step(0)
      host.step(0)
    end
  end
  -- ein Worker, der das Protokoll spricht (ohne echte Turtle)
  function w.worker(id, gear)
    local node = net.node(id)
    local wk = { node = node, got = {} }
    function wk.idle()
      node:send("job", "worker.idle", { role = "miner", gear = gear or {}, pos = { x = 0, y = 0, z = 0 }, fuel = 5000 })
      node:flush()
      w.step()
      wk.read()
    end
    function wk.read()
      node:poll(0)
      node:process(function(m) wk.got[#wk.got + 1] = m end)
    end
    function wk.last(topic)
      for i = #wk.got, 1, -1 do if wk.got[i].topic == topic then return wk.got[i].payload end end
    end
    function wk.say(topic, payload)
      local svc = topic:match("^(%a+)%.")
      node:send((svc == "map" or svc == "path") and svc or "job", topic, payload)
      node:flush()
      w.step()
      wk.read()
    end
    return wk
  end
  return w
end

local function area(x) return { x1 = x, y1 = 0, z1 = 0, x2 = x + 10, y2 = 10, z2 = 10 } end

test("Jobs: Zuteilung nach Ausruestung, dann accept, progress, complete", function()
  local w = world()
  local job = w.jobs:create({ type = "orehunt", area = area(0) }, "test")
  eq(job.state, "created")
  local plain = w.worker(5, {})
  plain.idle()
  eq(plain.last("job.assign"), nil, "ohne Geo Scanner keine Erzjagd")
  local scout = w.worker(6, { geo_scanner = true })
  scout.idle()
  local a = scout.last("job.assign")
  assert(a, "keine Zuteilung")
  eq(a.id, job.id) eq(a.epoch, 1) eq(w.jobs.state.jobs[job.id].state, "assigned")
  scout.say("job.accept", { id = a.id, epoch = 1 })
  eq(w.jobs.state.jobs[job.id].state, "accepted")
  scout.say("job.progress", { id = a.id, epoch = 1, progress = "orehunt 1/4" })
  eq(w.jobs.state.jobs[job.id].state, "running") eq(w.jobs.state.jobs[job.id].progress, "orehunt 1/4")
  scout.say("job.complete", { id = a.id, epoch = 1, result = "Fertig. 12 Erz" })
  eq(w.jobs.state.jobs[job.id].state, "complete")
  scout.say("job.complete", { id = a.id, epoch = 1, result = "Fertig. 12 Erz" }) -- doppelt
  eq(w.jobs.state.jobs[job.id].state, "complete", "doppelte Meldung aendert nichts")
end)

test("Jobs: Lease laeuft ab -> neu vergeben, alter Worker bekommt revoke", function()
  local w = world()
  local job = w.jobs:create({ type = "tunnel" }, "test")
  local a, b = w.worker(5), w.worker(6)
  a.idle()
  local asg = a.last("job.assign")
  a.say("job.accept", { id = asg.id, epoch = asg.epoch })
  sim.advance((require("jobsvc").LEASE + 1) * 1000) -- a meldet sich nicht mehr
  w.step()
  local j = w.jobs.state.jobs[job.id]
  eq(j.state, "created", "zurueck in der Warteschlange") eq(j.attempts, 1)
  b.idle()
  local asg2 = b.last("job.assign")
  eq(asg2.id, job.id) eq(asg2.epoch, 2)
  a.say("job.progress", { id = job.id, epoch = 1, progress = "bin wieder da" })
  local rv = a.last("job.revoke")
  assert(rv and rv.id == job.id, "alter Worker muss aufhoeren")
  eq(w.jobs.state.jobs[job.id].worker, 6, "gehoert weiter b")
end)

test("Jobs: ueberlappende Bereiche nie gleichzeitig", function()
  local w = world()
  local j1 = w.jobs:create({ type = "tunnel", area = area(0) }, "t")
  local j2 = w.jobs:create({ type = "tunnel", area = area(5) }, "t") -- ueberlappt j1
  local j3 = w.jobs:create({ type = "tunnel", area = area(50) }, "t")
  local a, b = w.worker(5), w.worker(6)
  a.idle()
  eq(a.last("job.assign").id, j1.id)
  b.idle()
  eq(b.last("job.assign").id, j3.id, "j2 muss warten, j3 ist frei")
  eq(w.jobs.state.jobs[j2.id].state, "created")
end)

test("Jobs: Prioritaet vor Alter", function()
  local w = world()
  w.jobs:create({ type = "tunnel", priority = 3 }, "t")
  local urgent = w.jobs:create({ type = "tunnel", priority = 9 }, "t")
  local a = w.worker(5)
  a.idle()
  eq(a.last("job.assign").id, urgent.id)
end)

test("Jobs: 'frei' waehrend die Zuteilung unterwegs ist -> keine Doppelvergabe", function()
  local w = world()
  local j1 = w.jobs:create({ type = "tunnel" }, "t")
  w.jobs:create({ type = "tunnel" }, "t")
  local a = w.worker(5)
  a.idle()
  a.got = {}
  a.idle() -- Zuteilung noch nicht verarbeitet, Worker meldet sich nochmal frei
  eq(a.last("job.assign"), nil, "keine zweite Zuteilung")
  eq(w.jobs.state.jobs[j1.id].state, "assigned")
  eq(w.jobs.state.jobs[j1.id].attempts, 0)
end)

test("Jobs: nach 3 Fehlschlaegen endgueltig failed", function()
  local w = world()
  local job = w.jobs:create({ type = "tunnel" }, "t")
  local a = w.worker(5)
  for i = 1, 3 do
    a.got = {}
    a.idle()
    local asg = a.last("job.assign")
    assert(asg, "Versuch " .. i .. " nicht zugeteilt")
    a.say("job.accept", { id = asg.id, epoch = asg.epoch })
    a.say("job.fail", { id = asg.id, epoch = asg.epoch, reason = "Lava", retry = true })
  end
  eq(w.jobs.state.jobs[job.id].state, "failed")
  a.got = {}
  a.idle()
  eq(a.last("job.assign"), nil)
end)

test("Jobs: Abbruch erreicht den Worker, Zustand ueberlebt Neustart", function()
  local w = world()
  local job = w.jobs:create({ type = "orehunt", params = { rounds = 2 } }, "t")
  local a = w.worker(5, { geo_scanner = true })
  a.idle()
  local asg = a.last("job.assign")
  a.say("job.accept", { id = asg.id, epoch = asg.epoch })
  w.jobs:cancel(job.id)
  w.step()
  a.read()
  assert(a.last("job.cancel"), "kein job.cancel beim Worker")
  local again = require("jobsvc").new(w.host, { dir = "/central" })
  eq(again.state.jobs[job.id].state, "cancelled")
  eq(again.state.jobs[job.id].params.rounds, 2)
end)

-- Teil B: echte Turtle mit Worker-Dienst ---------------------------------------
local function realTurtle(w)
  require("store").save("/.nav", { pos = { x = 705, y = 40, z = 605, f = 0 }, home = { x = 705, y = 40, z = 605, f = 0 }, gps = true })
  require("zones").add("z", 700, 0, 600, 800, 100, 700)
  settings.values["mq.enabled"] = true
  settings.values["claude.role"] = "miner"
  cc.label = "Miner1"
  local sync = require("sync")
  sync.now = sim.now
  local tlink = w.net.link()
  local receive = tlink.receive
  tlink.down = true
  tlink.close = function() tlink.down = true end
  tlink.receive = function(t)
    local deadline = sim.clock + (t or 0) * 1000
    while true do
      w.step(1) -- Gateway und Zentrale arbeiten parallel
      local packet = receive(0)
      if packet then return packet end
      if sim.clock >= deadline then return nil end
      sim.advance(250)
    end
  end
  sync.linkFor = function()
    tlink.node = sync.getNode()
    tlink.down = false
    return tlink
  end
  turtle.getItemDetail = function(slot)
    if slot == 2 then return { name = "computercraft:wireless_modem_advanced", count = 1 } end
  end
  turtle.getEquippedRight = function() return nil end
  turtle.getFuelLevel = function() return 20000 end
  local wrap = peripheral.wrap
  peripheral.wrap = function(side) if side == "left" then return {} end end
  local runner = require("jobrunner")
  runner.say = function() end
  runner.init()
  return runner, function()
    peripheral.wrap = wrap
    turtle.getItemDetail = function() return nil end
    turtle.getFuelLevel = function() return 1000 end
  end
end

test("Worker: echte Turtle holt sich einen Auftrag und arbeitet ihn ab", function()
  local w = world()
  local job = w.jobs:create({ type = "tunnel", params = { length = 3, width = 1, height = 1,
    start = { x = 710, y = 40, z = 610, f = 0 } } }, "test")
  local runner, done = realTurtle(w)
  local states = {}
  for _ = 1, 12 do
    sim.advance(16000)
    states[#states + 1] = runner.step()
    if w.jobs.state.jobs[job.id].state == "complete" then break end
  end
  done()
  local j = w.jobs.state.jobs[job.id]
  eq(j.state, "complete", "Verlauf: " .. table.concat(states, ","))
  assert(j.result:find("^Fertig"), j.result)
  eq(j.worker, 7, "Turtle-ID (os.getComputerID der Attrappe, siehe tests/cc.lua)")
  local p = require("nav").pos()
  eq(p.x, 710) eq(p.z, 613, "Tunnel 3 lang ab Startpunkt")
  eq(runner.state().job, nil, "Worker wieder frei")
end)

-- bricht den Auftrag ab, sobald when(job) zutrifft, und prueft, dass die Turtle frueh aufhoert
local function cancelWhen(when)
  local w = world()
  local job = w.jobs:create({ type = "tunnel", params = { length = 200, width = 1, height = 1,
    start = { x = 710, y = 40, z = 610, f = 0 } } }, "test")
  local runner, done = realTurtle(w)
  settings.values["mq.interval"] = 0 -- bei jedem Schritt syncen, damit der Abbruch schnell ankommt
  local cancelled = false
  local step = w.step
  w.step = function(n)
    step(n)
    if not cancelled and when(w.jobs.state.jobs[job.id]) then
      cancelled = true
      w.jobs:cancel(job.id)
    end
  end
  for _ = 1, 6 do
    sim.advance(16000)
    runner.step()
    if cancelled and not runner.state().job then break end
  end
  done()
  eq(cancelled, true, "Abbruch nie ausgeloest")
  eq(w.jobs.state.jobs[job.id].state, "cancelled")
  eq(runner.state().job, nil, "Worker hat aufgehoert und ist wieder frei")
  return require("nav").pos()
end

test("Worker: Abbruch direkt nach der Zuteilung - die Turtle faengt gar nicht erst an", function()
  local p = cancelWhen(function(j) return j.state == "accepted" or j.state == "running" end)
  eq(p.z, 605, "ist nicht losgefahren")
end)

test("Worker: Abbruch mitten im Tunnel stoppt sofort", function()
  local p = cancelWhen(function(j) return j.progress and j.progress:find("tunnel 5/") end)
  assert(p.z >= 614 and p.z <= 620, "sollte kurz nach Meter 5 stehen, steht bei z=" .. p.z)
end)

-- P3.2: Kosten, Map- und Path-Dienst ------------------------------------------
test("Kosten: eine Formel fuer Turtle, Job- und Path-Dienst", function()
  local cost = require("cost")
  local nav = require("nav")
  nav.TRAVEL_Y = 110
  local a, b = { x = 0, y = 20, z = 0 }, { x = 100, y = 64, z = 50 }
  eq(cost.trip(a, b, 110), nav.tripCost(a, b))
  eq(cost.trip(a, { x = 3, y = 20, z = 4 }, 110), 7, "kurzer Weg direkt")
  assert(cost.jobBudget("tunnel", { length = 10, width = 3, height = 3 }) > 30)
  local need = cost.need({ type = "tunnel", params = { length = 10, start = b } },
    { pos = a, depot = { x = 0, y = 64, z = 0 } }, 110)
  eq(need, cost.RESERVE + cost.jobBudget("tunnel", { length = 10 }) + cost.trip(a, b, 110)
    + cost.trip(b, { x = 0, y = 64, z = 0 }, 110))
end)

test("Jobs: zu wenig Fuel -> Auftrag geht an einen anderen Worker", function()
  local w = world()
  local job = w.jobs:create({ type = "tunnel", params = { length = 50, start = { x = 300, y = 40, z = 0 } } }, "t")
  local poor = w.worker(5)
  poor.node:send("job", "worker.idle", { role = "miner", gear = {}, pos = { x = 0, y = 40, z = 0 }, fuel = 300 })
  poor.node:flush()
  w.step()
  poor.read()
  eq(poor.last("job.assign"), nil, "300 Fuel reichen nicht")
  local rich = w.worker(6)
  rich.node:send("job", "worker.idle", { role = "miner", gear = {}, pos = { x = 0, y = 40, z = 0 }, fuel = 20000 })
  rich.node:flush()
  w.step()
  rich.read()
  eq(rich.last("job.assign").id, job.id)
end)

test("Path-Dienst: Fuel-Schaetzung ueber TurtleMQ", function()
  local w = world()
  local asker = w.worker(9)
  asker.say("path.estimate", { from = { x = 0, y = 20, z = 0 }, to = { x = 100, y = 64, z = 50 }, travel_y = 110 })
  local r = asker.last("path.estimate.reply")
  assert(r, "keine Antwort")
  eq(r.fuel, require("cost").trip({ x = 0, y = 20, z = 0 }, { x = 100, y = 64, z = 50 }, 110))
end)

test("Map: Zonen und Orte kommen bei der Turtle an, Loeschen auch", function()
  local w = world()
  local runner, done = realTurtle(w)
  local zones = require("zones")
  local nav = require("nav")
  w.map:addZone("mine1", 700, 0, 600, 750, 60, 650)
  w.map:setMaxY(55)
  w.map:setPlace("depot", 740, 64, 615, 2)
  w.map:setPlace("home:Miner1", 730, 70, 640, 3)
  w.map:setPlace("home:Andere", 1, 2, 3, 0)
  for _ = 1, 3 do sim.advance(16000) runner.step() end
  eq(zones.rev(), w.map.state.rev, "Stand uebernommen")
  eq(zones.check({ x = 720, y = 40, z = 620 }, "minecraft:stone", true), true, "in mine1")
  eq(zones.check({ x = 790, y = 40, z = 620 }, "minecraft:stone", true), false, "lokale Testzone ist ersetzt")
  eq(zones.check({ x = 720, y = 58, z = 620 }, "minecraft:stone", true), false, "Hoehenlimit 55")
  eq(nav.depot().x, 740) eq(nav.depot().f, 2)
  eq(nav.home().z, 640, "eigener Heimplatz") eq(nav.home().f, 3)
  w.map:deleteZone("mine1")
  for _ = 1, 3 do sim.advance(16000) runner.step() end
  done()
  eq(zones.check({ x = 720, y = 40, z = 620 }, "minecraft:stone", true), false, "Zone geloescht -> kein Graben")
end)

test("Map: ohne zentrale Zonen behaelt die Turtle ihre lokalen", function()
  local w = world()
  local runner, done = realTurtle(w)
  for _ = 1, 3 do sim.advance(16000) runner.step() end
  done()
  local zones = require("zones")
  eq(zones.rev(), 0)
  eq(zones.check({ x = 720, y = 40, z = 620 }, "minecraft:stone", true), true, "lokale Zone gilt weiter")
end)

test("Map: gleicher Stand -> keine Antwort, kein unnoetiger Funk", function()
  local w = world()
  w.map:addZone("a", 0, 0, 0, 10, 10, 10)
  local wk = w.worker(5)
  wk.say("map.get", { rev = 0 })
  assert(wk.last("map.data"), "neuer Stand muss kommen")
  wk.got = {}
  wk.say("map.get", { rev = w.map.state.rev })
  eq(wk.last("map.data"), nil)
end)

test("Worker: zu wenig Fuel im Leerlauf -> faehrt selbst tanken, aber nicht dauernd", function()
  local w = world()
  local runner, done = realTurtle(w)
  turtle.getFuelLevel = function() return 500 end
  local nav = require("nav")
  nav.setDepot({ x = 760, y = 40, z = 605, f = 0 })
  local visited = false
  local unload = nav.unload
  nav.unload = function()
    visited = nav.pos().x == 760
    return unload()
  end
  local r1 = runner.step()
  sim.advance(16000)
  local r2 = runner.step()
  done()
  eq(r1, "getankt") eq(visited, true, "war am Lager")
  eq(nav.pos().x, 705, "wieder daheim")
  eq(r2, "leerlauf", "nicht sofort nochmal")
end)
