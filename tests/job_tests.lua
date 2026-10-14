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
    gear = gear or { chest = true }
    local node = net.node(id)
    local wk = { node = node, got = {} }
    function wk.idle()
      node:send("job", "worker.idle", { role = "miner", gear = gear, pos = { x = 0, y = 0, z = 0 }, fuel = 5000 })
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
  local plain = w.worker(5, { chest = true })
  plain.idle()
  eq(plain.last("job.assign"), nil, "ohne Geo Scanner keine Erzjagd")
  local noChest = w.worker(8, { geo_scanner = true })
  noChest.idle()
  eq(noChest.last("job.assign"), nil, "ohne Kiste keine Erzjagd")
  local scout = w.worker(6, { geo_scanner = true, chest = true })
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
  local a = w.worker(5, { geo_scanner = true, chest = true })
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
local function realTurtle(w, navState)
  if navState ~= false then
    require("store").save("/.nav", navState or { pos = { x = 705, y = 40, z = 605, f = 0 }, home = { x = 705, y = 40, z = 605, f = 0 }, gps = true })
  end
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
    if slot == 3 then return { name = "advancedperipherals:geo_scanner", count = 1 } end
    if slot == 4 then return { name = "minecraft:chest", count = 1 } end
  end
  turtle.getEquippedRight = function() return nil end
  turtle.getFuelLevel = function() return 20000 end
  local wrap = peripheral.wrap
  peripheral.wrap = function(side) if side == "left" then return {} end end
  local runner = require("jobrunner")
  runner.setPrinter(function() end)
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
  -- Worker fahren nach dem Auftrag heim (vorher Zwischenkiste eingepackt)
  eq(p.x, 705) eq(p.z, 605, "wieder daheim")
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
  poor.node:send("job", "worker.idle", { role = "miner", gear = { chest = true }, pos = { x = 0, y = 40, z = 0 }, fuel = 300 })
  poor.node:flush()
  w.step()
  poor.read()
  eq(poor.last("job.assign"), nil, "300 Fuel reichen nicht")
  local rich = w.worker(6)
  rich.node:send("job", "worker.idle", { role = "miner", gear = { chest = true }, pos = { x = 0, y = 40, z = 0 }, fuel = 20000 })
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

test("Worker: nach einem Auftrag mit Heimfahrt bleibt die Ausruestung dabei (kein Modem in der Toolbox)", function()
  local w = world()
  w.jobs:create({ type = "tunnel", params = { length = 2, width = 1, height = 1, home = true,
    start = { x = 710, y = 40, z = 610, f = 0 } } }, "test")
  local runner, done = realTurtle(w)
  local gear = require("gear")
  local stored = 0
  gear.store = function() stored = stored + 1 return true, "" end
  for _ = 1, 8 do
    sim.advance(16000)
    runner.step()
    if w.jobs.state.jobs.J1.state == "complete" then break end
  end
  done()
  eq(w.jobs.state.jobs.J1.state, "complete")
  eq(stored, 0, "Worker darf seine Ausruestung nicht in die Toolbox legen")
end)

-- Toolbox unter dem Heimplatz nachbilden
local function toolbox(items)
  local wrap = peripheral.wrap
  peripheral.wrap = function(side)
    if side == "bottom" then
      return { list = function()
        local l = {}
        for i, name in ipairs(items) do l[i] = { name = name, count = 1 } end
        return l
      end }
    end
    return wrap(side)
  end
end

test("Worker: fehlende Ausruestung holt er sich daheim aus der Toolbox", function()
  local w = world()
  local runner, done = realTurtle(w)
  toolbox({ "advancedperipherals:geo_scanner", "minecraft:chest" })
  turtle.getItemDetail = function(slot) -- nur noch das Modem dabei
    if slot == 2 then return { name = "computercraft:wireless_modem_advanced", count = 1 } end
  end
  local gear = require("gear")
  local asked
  gear.take = function(items) asked = items return true, "ok" end
  local r = runner.step() -- steht daheim (Heimplatz = Startposition)
  done()
  eq(r, "ausgeruestet")
  eq(table.concat(asked, ","), "geo_scanner,minecraft:chest")
end)

test("Worker: fehlt Ausruestung und er ist nicht daheim, fliegt er erst heim zur Toolbox", function()
  local w = world()
  local runner, done = realTurtle(w)
  local nav = require("nav")
  nav.setHome({ x = 730, y = 40, z = 640, f = 0 }) -- steht woanders als daheim
  turtle.getItemDetail = function() return nil end -- gar nichts dabei, nicht einmal das Modem
  local gear = require("gear")
  local takenAt
  gear.take = function(items)
    local p = nav.pos()
    takenAt = ("%d %d %d"):format(p.x, p.y, p.z)
    return true, "ok"
  end
  local r = runner.step()
  done()
  eq(r, "ausgeruestet")
  eq(takenAt, "730 40 640", "erst daheim aus der Toolbox genommen")
end)

test("Worker: fest ausgeruestetes Modem zaehlt als vorhanden", function()
  local w = world()
  local runner, done = realTurtle(w)
  turtle.getItemDetail = function(slot) -- Modem NICHT im Inventar, nur Scanner und Kiste
    if slot == 3 then return { name = "advancedperipherals:geo_scanner", count = 1 } end
    if slot == 4 then return { name = "minecraft:chest", count = 1 } end
  end
  local getType, call = peripheral.getType, peripheral.call
  peripheral.getType = function(side) if side == "right" then return "modem" end end
  peripheral.call = function(side, method) if side == "right" and method == "isWireless" then return true end end
  local gear = require("gear")
  local asked
  gear.take = function(items) asked = items return true end
  local r = runner.step()
  local info = runner.gearInfo()
  peripheral.getType, peripheral.call = getType, call
  done()
  eq(asked, nil, "nichts aus der Toolbox holen")
  eq(info.modem, true)
  eq(r, "leerlauf")
end)

test("Bootstrap: 'bootstrap miner' ohne Rueckfragen schaltet TurtleMQ ein", function()
  cc.web = {
    ["main/update.lua"] = assert(io.open("update.lua")):read("*a"),
    ["api:main"] = { sha = "abc1234def" },
    ["abc1234def/manifests/miner.txt"] = "nav.lua\n",
    ["abc1234def/nav.lua"] = "n",
  }
  loadfile("bootstrap.lua")("miner")
  eq(settings.values["mq.enabled"], true)
end)

test("Jobs: Worker erfaehrt, warum er nichts bekommt", function()
  local w = world()
  w.jobs:create({ type = "orehunt" }, "t")
  local a = w.worker(5, { chest = true })
  a.idle()
  local none = a.last("job.none")
  assert(none and none.reasons:find("J1: fehlt geo_scanner"), none and none.reasons)
  assert(w.jobs.log[1]:find("bekommt nichts"), w.jobs.log[1])
end)

test("Worker: Zentrale meldet zu wenig Fuel -> faehrt so viel tanken, wie der Auftrag braucht", function()
  local w = world()
  local job = w.jobs:create({ type = "tunnel", params = { length = 300, width = 3, height = 3,
    start = { x = 710, y = 40, z = 610, f = 0 } } }, "t")
  local runner, done = realTurtle(w)
  turtle.getFuelLevel = function() return 1500 end -- ueber der Mindestmenge, aber zu wenig fuer den Auftrag
  local nav = require("nav")
  local targetWhileRefuel
  nav.unload = function() targetWhileRefuel = nav.FUEL_TARGET return true, 0 end
  local results = {}
  for _ = 1, 4 do
    sim.advance(16000)
    results[#results + 1] = runner.step()
    if targetWhileRefuel then break end
  end
  done()
  local need = require("cost").need(w.jobs.state.jobs[job.id], { pos = { x = 705, y = 40, z = 605 },
    depot = { x = 705, y = 40, z = 605 } }, 110)
  assert(targetWhileRefuel, "ist nicht tanken gefahren: " .. table.concat(results, ","))
  assert(targetWhileRefuel >= need, ("tankt nur bis %d, braucht %d"):format(targetWhileRefuel, need))
end)

test("Worker: steht woanders, Scanner und Kiste liegen daheim -> trotzdem brauchbar, holt sie fuer den Auftrag", function()
  local w = world()
  local runner, done = realTurtle(w)
  local nav = require("nav")
  local gear = require("gear")
  -- zuerst daheim: Toolbox anschauen (Scanner und Kiste liegen drin, die Turtle hat nur das Modem)
  local carried = { [2] = { name = "computercraft:wireless_modem_advanced", count = 1 } }
  turtle.getItemDetail = function(slot) return carried[slot] end
  toolbox({ "advancedperipherals:geo_scanner", "minecraft:chest" })
  local takenAt
  gear.take = function(items)
    local p = nav.pos()
    takenAt = ("%d %d %d"):format(p.x, p.y, p.z)
    carried[3] = { name = "advancedperipherals:geo_scanner", count = 1 }
    carried[4] = { name = "minecraft:chest", count = 1 }
    return true, "ok"
  end
  runner.state().toolbox = { geo_scanner = true, chest = true }
  -- jetzt steht sie woanders
  nav.setHome({ x = 705, y = 40, z = 605, f = 0 })
  nav.goTo(720, 40, 620, "xzy", false)

  local info, needsHome = runner.gearInfo()
  eq(info.geo_scanner, true) eq(info.chest, true) eq(needsHome, true)
  eq(runner.step(), "leerlauf", "fliegt nicht ohne Grund heim")

  local job = w.jobs:create({ type = "tunnel", params = { length = 2, width = 1, height = 1,
    start = { x = 712, y = 40, z = 612, f = 0 } } }, "t")
  for _ = 1, 8 do
    sim.advance(16000)
    runner.step()
    if w.jobs.state.jobs[job.id].state == "complete" then break end
  end
  done()
  eq(w.jobs.state.jobs[job.id].state, "complete", "Auftrag erledigt")
  eq(takenAt, "705 40 605", "vorher daheim die Ausruestung geholt")
end)

test("Kosten: liegt die Ausruestung daheim, wird der Umweg eingerechnet", function()
  local cost = require("cost")
  local job = { type = "tunnel", params = { length = 5, start = { x = 100, y = 40, z = 0 } } }
  local direct = cost.need(job, { pos = { x = 0, y = 40, z = 0 } }, 110)
  local detour = cost.need(job, { pos = { x = 0, y = 40, z = 0 }, needs_home = true, home = { x = -200, y = 40, z = 0 } }, 110)
  assert(detour > direct + 300, ("Umweg fehlt: %d vs %d"):format(detour, direct))
end)

test("Worker: veraltetes Wissen ueber die Toolbox -> fliegt nachschauen, wenn die Zentrale 'fehlt' meldet", function()
  local w = world()
  w.jobs:create({ type = "orehunt", params = { start = { x = 712, y = 40, z = 612, f = 0 } } }, "t")
  local runner, done = realTurtle(w)
  local nav, gear = require("nav"), require("gear")
  local carried = { [2] = { name = "computercraft:wireless_modem_advanced", count = 1 },
    [4] = { name = "minecraft:chest", count = 1 } }
  turtle.getItemDetail = function(slot) return carried[slot] end
  -- vor langer Zeit angeschaut: damals ohne Scanner. Inzwischen liegt einer drin.
  runner.state().toolbox = { chest = true }
  runner.state().toolboxAt = sim.now() - 3600 * 1000
  toolbox({ "advancedperipherals:geo_scanner" })
  local looked = false
  gear.take = function(items)
    looked = true
    carried[3] = { name = "advancedperipherals:geo_scanner", count = 1 }
    return true, "ok"
  end
  nav.goTo(720, 40, 620, "xzy", false) -- steht woanders
  for _ = 1, 4 do
    sim.advance(16000)
    runner.step()
    if looked then break end
  end
  local status = table.concat(runner.status(), " | ")
  done()
  eq(looked, true, "ist heim nachschauen geflogen")
  assert(status:find("Toolbox daheim: geo_scanner"), status)
end)

test("Worker: Status zeigt, wenn unter dem Heimplatz keine Toolbox ist", function()
  local w = world()
  local runner, done = realTurtle(w)
  turtle.getItemDetail = function(slot)
    if slot == 2 then return { name = "computercraft:wireless_modem_advanced", count = 1 } end
  end
  runner.step() -- daheim, aber unten keine Kiste (peripheral.wrap("bottom") = nil)
  local status = table.concat(runner.status(), " | ")
  done()
  assert(status:find("keine Kiste unter dem Heimplatz"), status)
end)

test("Worker: Tunnel-Auftrag endet daheim, nicht unter der Erde", function()
  local w = world()
  local job = w.jobs:create({ type = "tunnel", params = { length = 3, width = 1, height = 1,
    start = { x = 710, y = 40, z = 610, f = 0 } } }, "t")
  local runner, done = realTurtle(w)
  for _ = 1, 8 do
    sim.advance(16000)
    runner.step()
    if w.jobs.state.jobs[job.id].state == "complete" then break end
  end
  done()
  local p, h = require("nav").pos(), require("nav").home()
  eq(w.jobs.state.jobs[job.id].state, "complete")
  eq(("%d %d %d"):format(p.x, p.y, p.z), ("%d %d %d"):format(h.x, h.y, h.z), "wieder daheim")
  eq(runner.state().lastStart.z, 610, "Einstieg gemerkt")
end)

test("Worker: kommt er nicht nach oben, faehrt er erst zum letzten Einstieg", function()
  local w = world()
  local runner, done = realTurtle(w)
  local nav, gear = require("nav"), require("gear")
  turtle.getItemDetail = function(slot)
    if slot == 2 then return { name = "computercraft:wireless_modem_advanced", count = 1 } end
  end
  runner.state().lastStart = { x = 712, y = 40, z = 612 }
  nav.goTo(712, 40, 618, "xzy", false) -- im Tunnel, 6 Bloecke hinter dem Einstieg
  local goHome = nav.goHome
  local calls = {}
  nav.goHome = function()
    local p = nav.pos()
    calls[#calls + 1] = ("%d %d %d"):format(p.x, p.y, p.z)
    if p.z == 618 then return false, "Weg nach oben blockiert: Darf hier nicht graben" end
    return goHome()
  end
  gear.take = function() return true, "ok" end
  local r = runner.step()
  local status = table.concat(runner.status(), " | ")
  done()
  eq(calls[1], "712 40 618", "erst direkt versucht")
  eq(calls[2], "712 40 612", "dann vom Einstieg aus")
  eq(r, "ausgeruestet")
  assert(status:find("Letzte Meldung"), status)
end)

test("Worker: misst sich beim Start per GPS ein und kontrolliert im Leerlauf", function()
  local w = world()
  local runner, done = realTurtle(w)
  local nav = require("nav")
  local calls = 0
  nav.calibrate = function() calls = calls + 1 return true end
  runner.step()
  eq(calls, 1, "beim Start eingemessen")
  -- GPS sagt etwas anderes als die gedachte Position -> neu einmessen
  nav.locate = function() return { x = 999, y = 40, z = 605 } end
  sim.advance((runner.GPS_CHECK + 1) * 1000)
  runner.step()
  eq(calls, 2, "Abweichung erkannt und neu eingemessen")
  -- passt -> nichts tun
  local p = nav.pos()
  nav.locate = function() return { x = p.x, y = p.y, z = p.z } end
  sim.advance((runner.GPS_CHECK + 1) * 1000)
  runner.step()
  done()
  eq(calls, 2)
end)

test("Worker: ohne GPS werden Orte von der Zentrale nicht uebernommen", function()
  require("store").save("/.nav", { pos = { x = 0, y = 0, z = 0, f = 0 }, home = { x = 0, y = 0, z = 0, f = 0 }, gps = false })
  local w = world()
  local runner, done = realTurtle(w)
  -- realTurtle setzt eine GPS-Position; fuer diesen Test wieder ohne GPS
  require("store").save("/.nav", { pos = { x = 0, y = 0, z = 0, f = 0 }, home = { x = 0, y = 0, z = 0, f = 0 }, gps = false })
  for _, m in ipairs({ "nav", "jobrunner", "mine", "path" }) do package.loaded[m] = nil end
  local nav = require("nav")
  nav.calibrate = function() return false, "kein Signal" end
  runner = require("jobrunner")
  runner.setPrinter(function() end)
  runner.init()
  w.map:setPlace("home:Miner1", 730, 70, 640, 3)
  require("sync").onMessage({ topic = "map.data", payload = w.map:data() })
  local status = table.concat(runner.status(), " | ")
  done()
  eq(nav.home().x, 0, "Heimplatz unveraendert ohne GPS")
  assert(status:find("erst gpsfix"), status)
end)

test("Nav: kurzer Heimweg durch eine Wand ueber dem Hoehenlimit -> fliegt ueber die Reisehoehe", function()
  require("store").save("/.nav", { pos = { x = 700, y = 70, z = 600, f = 3 },
    home = { x = 705, y = 70, z = 600, f = 0 }, gps = true })
  local nav = require("nav")
  nav.TRAVEL_Y = 110
  -- Wand bei x = 702, von y 60 bis 80 (ueber dem Hoehenlimit 50, also nicht abbaubar)
  local function wall(t) return t.x == 702 and t.z == 600 and t.y >= 60 and t.y <= 80 end
  local fwd, det, insp = turtle.forward, turtle.detect, turtle.inspect
  turtle.forward = function() return not wall(nav.target("front")) end
  turtle.detect = function() return wall(nav.target("front")) end
  turtle.inspect = function()
    if wall(nav.target("front")) then return true, { name = "minecraft:stone" } end
    return false
  end
  local ok, err = nav.goHome()
  turtle.forward, turtle.detect, turtle.inspect = fwd, det, insp
  assert(ok, tostring(err))
  local p = nav.pos()
  eq(("%d %d %d"):format(p.x, p.y, p.z), "705 70 600", "daheim angekommen")
end)

test("Nav: Fehlermeldung nennt Ort und Block", function()
  require("store").save("/.nav", { pos = { x = 0, y = 70, z = 0, f = 3 }, home = { x = 0, y = 70, z = 0, f = 0 }, gps = true })
  local nav = require("nav")
  local det, insp = turtle.detect, turtle.inspect
  turtle.detect = function() return true end
  turtle.inspect = function() return true, { name = "minecraft:oak_leaves" } end
  local ok, err = nav.dig("front")
  turtle.detect, turtle.inspect = det, insp
  eq(ok, false)
  assert(err:find("bei 1 70 0: minecraft:oak_leaves"), err)
end)

test("Nav: neu platzierte Turtle hat keinen Heimplatz, GPS-Einmessen erfindet keinen", function()
  local nav = require("nav") -- keine Zustandsdatei: frisch hingestellt
  eq(nav.homeKnown(), false)
  assert(nav.where():find("Zuhause nicht gesetzt"), nav.where())
  local ok, err = nav.goHome()
  eq(ok, false) assert(err:find("Kein Heimplatz"), err)
  -- GPS-Einmessen: Position wird Weltkoordinate, der Heimplatz bleibt unbekannt
  _G.gps = { locate = function() return 500, 64, 500 end }
  peripheral.getType = function(side) if side == "right" then return "modem" end end
  local call = peripheral.call
  peripheral.call = function(side, m) if side == "right" and m == "isWireless" then return true end end
  local ok2 = nav.calibrate()
  peripheral.getType = function() return nil end
  peripheral.call = call
  _G.gps = nil
  eq(ok2, true)
  eq(nav.homeKnown(), false, "Platzhalter bleibt Platzhalter")
  nav.setHome()
  eq(nav.homeKnown(), true)
end)

test("Worker: holt beim Start Lager und Heimplatz frisch, auch ohne neuen Kartenstand", function()
  local w = world()
  w.map:addZone("z", 700, 0, 600, 800, 100, 700)
  w.map:setPlace("home:Miner1", 730, 40, 640, 3)
  local runner, done = realTurtle(w)
  local zones, nav = require("zones"), require("nav")
  -- die Turtle kennt den Kartenstand schon, aber ihr Heimplatz ist falsch (z.B. beim Hinstellen gesetzt)
  zones.replace(w.map.state.zones, w.map.state.maxY, w.map.state.rev)
  nav.setHome({ x = 1, y = 2, z = 3, f = 0 })
  nav.calibrate = function() return true end
  for _ = 1, 3 do sim.advance(16000) runner.step() end
  done()
  eq(nav.home().x, 730, "Heimplatz von der Zentrale uebernommen")
  eq(nav.home().f, 3)
end)

-- GPS-Einmessen mit nachgebildetem GPS: die Turtle steht wirklich bei real (x, y, z)
local function withGps(real, fn)
  local nav = require("nav")
  _G.gps = { locate = function()
    -- liefert die echte Position plus die Bewegung seit Beginn (fuer die Richtungsmessung)
    local p = nav.pos()
    return real.x + (p.x - real.sx), real.y + (p.y - real.sy), real.z + (p.z - real.sz)
  end }
  local getType, call = peripheral.getType, peripheral.call
  peripheral.getType = function(side) if side == "right" then return "modem" end end
  peripheral.call = function(side, m) if side == "right" and m == "isWireless" then return true end end
  local ok, err = pcall(fn)
  peripheral.getType, peripheral.call = getType, call
  _G.gps = nil
  assert(ok, err)
end

test("Nav: Turtle mit GPS woanders hingestellt -> Heim- und Lagerplatz bleiben, wo sie sind", function()
  -- gespeichert: stand bei 700 70 600, Heimplatz 705 70 600 (Weltkoordinaten)
  require("store").save("/.nav", { pos = { x = 700, y = 70, z = 600, f = 0 },
    home = { x = 705, y = 70, z = 600, f = 2 }, depot = { x = 740, y = 64, z = 615, f = 2 }, gps = true })
  local nav = require("nav")
  -- wirklich steht sie jetzt 30 Bloecke hoeher und woanders
  withGps({ x = 650, y = 100, z = 580, sx = 700, sy = 70, sz = 600 }, function()
    assert(nav.calibrate())
  end)
  local p, h, d = nav.pos(), nav.home(), nav.depot()
  eq(("%d %d %d"):format(p.x, p.y, p.z), "650 100 580", "Position neu gemessen")
  eq(("%d %d %d %d"):format(h.x, h.y, h.z, h.f), "705 70 600 2", "Heimplatz unveraendert")
  eq(("%d %d %d"):format(d.x, d.y, d.z), "740 64 615", "Lager unveraendert")
end)

test("Nav: erstes Einmessen (bisher relativ) rechnet einen gesetzten Heimplatz um", function()
  require("store").save("/.nav", { pos = { x = 0, y = 0, z = 0, f = 0 },
    home = { x = 0, y = 0, z = -2, f = 0 }, gps = false }) -- Heimplatz 2 Bloecke hinter dem Start
  local nav = require("nav")
  withGps({ x = 500, y = 64, z = 500, sx = 0, sy = 0, sz = 0 }, function()
    assert(nav.calibrate())
  end)
  local h = nav.home()
  eq(("%d %d %d"):format(h.x, h.y, h.z), "500 64 498", "relativ -> Welt umgerechnet")
end)

-- ===== Szenario-Tests: echte Turtle im Spiel nachgebildet =====
-- Die Welt kennt die WIRKLICHE Position der Turtle (real). Bewegungen aendern sie, GPS meldet sie.
-- Die Turtle selbst kennt nur, was in /.nav steht. Dateien ueberleben Abbauen/Hinstellen/Neustart.
-- Richtungen: 0 Sued (+z), 1 West (-x), 2 Nord (-z), 3 Ost (+x)
local WDX, WDZ = { [0] = 0, [1] = -1, [2] = 0, [3] = 1 }, { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }

local function physical(real)
  local saved = {}
  for _, k in ipairs({ "forward", "back", "up", "down", "turnLeft", "turnRight" }) do saved[k] = turtle[k] end
  turtle.forward = function() real.x, real.z = real.x + WDX[real.f], real.z + WDZ[real.f] return true end
  turtle.back = function() real.x, real.z = real.x - WDX[real.f], real.z - WDZ[real.f] return true end
  -- jede besuchte Stelle merken (real.visited["x y z"] = true)
  real.visited = real.visited or {}
  local function mark() real.visited[("%d %d %d"):format(real.x, real.y, real.z)] = true end
  local fwd, bck = turtle.forward, turtle.back
  turtle.forward = function() fwd() mark() return true end
  turtle.back = function() bck() mark() return true end
  turtle.up = function() real.y = real.y + 1 mark() return true end
  turtle.down = function() real.y = real.y - 1 mark() return true end
  turtle.turnRight = function() real.f = (real.f + 1) % 4 return true end
  turtle.turnLeft = function() real.f = (real.f + 3) % 4 return true end
  _G.gps = { locate = function() return real.x, real.y, real.z end }
  local getType, call = peripheral.getType, peripheral.call
  peripheral.getType = function(side) if side == "right" then return "modem" end end
  peripheral.call = function(side, m) if side == "right" and m == "isWireless" then return true end end
  return function()
    for k, f in pairs(saved) do turtle[k] = f end
    peripheral.getType, peripheral.call = getType, call
    _G.gps = nil
  end
end

-- Turtle (neu) starten: Programme frisch laden wie nach einem Neustart, dann n Runden worker
local function boot(w, n)
  for _, m in ipairs({ "nav", "jobrunner", "mine", "path", "gear", "sync" }) do package.loaded[m] = nil end
  local runner, done = realTurtle(w, false)
  -- wie im Spiel: nur Spitzhacke und Modem fest ausgeruestet, Scanner und Kiste liegen in der Toolbox
  turtle.getItemDetail = function() return nil end
  for _ = 1, n or 6 do sim.advance(16000) runner.step() end
  done()
  return require("nav"), runner
end

local function at(t) return ("%d %d %d"):format(t.x, t.y, t.z) end

local function scenario(name, o)
  test("Szenario: " .. name, function()
    local w = world()
    w.map:addZone("z", 0, 0, 0, 1000, 100, 1000)
    if o.before then o.before(w) end
    if o.central then w.map:setPlace("home:Miner1", o.central.x, o.central.y, o.central.z, o.central.f) end
    if o.nav then require("store").save("/.nav", o.nav) end
    local real = o.real
    local undo = physical(real)
    local ok, err = pcall(function()
      local nav, runner = boot(w)
      local status = table.concat(runner.status(), " | ")
      eq(at(nav.home()), at(o.home), "gespeicherter Heimplatz | " .. status)
      eq(at(real), at(o.home), "Turtle steht wirklich daheim | " .. status)
      eq(at(nav.pos()), at(real), "gedachte = wirkliche Position")
      eq(nav.pos().f, real.f, "gedachte = wirkliche Blickrichtung")
      if o.never then assert(not real.visited[at(o.never)], "war beim falschen Heimplatz " .. at(o.never)) end
      if o.after then o.after(w, real, nav) end
    end)
    undo()
    assert(ok, err)
  end)
end

local HOME = { x = 705, y = 70, z = 600, f = 2 }

scenario("neu hingestellt, Zentrale kennt den Heimplatz -> fliegt heim", {
  central = HOME,
  real = { x = 650, y = 90, z = 580, f = 1 },
  home = HOME,
})

scenario("mit GPS woanders (30 hoeher) hingestellt, Heimplatz gespeichert -> fliegt heim", {
  nav = { pos = { x = 705, y = 70, z = 600, f = 2 }, home = HOME, gps = true, homeSet = true },
  real = { x = 650, y = 100, z = 580, f = 3 },
  home = HOME,
})

scenario("mit GPS woanders hingestellt, Zentrale hat denselben Heimplatz", {
  central = HOME,
  nav = { pos = { x = 705, y = 70, z = 600, f = 2 }, home = HOME, gps = true, homeSet = true },
  real = { x = 650, y = 100, z = 580, f = 0 },
  home = HOME,
})

scenario("falscher Heimplatz aus altem Fehler gespeichert, Zentrale hat den richtigen", {
  central = HOME,
  nav = { pos = { x = 650, y = 100, z = 580, f = 0 }, home = { x = 705, y = 40, z = 600, f = 2 }, gps = true,
    homeSet = true },
  real = { x = 650, y = 100, z = 580, f = 0 },
  home = HOME,
  never = { x = 705, y = 40, z = 600 }, -- nicht erst zum alten Heimplatz fliegen
})

scenario("alte Datei ohne GPS: daheim sethome, dann woanders hingestellt -> erstes Einmessen", {
  -- ohne GPS kann die Turtle nach dem Versetzen nicht wissen, wo sie ist: der Heimplatz gilt relativ zur
  -- gedachten Position. Hier wurde sie nicht versetzt, nur gedreht gespeichert (relativ f 0 = wirklich West).
  nav = { pos = { x = 0, y = 0, z = 0, f = 0 }, home = { x = 0, y = 0, z = 0, f = 0 }, gps = false },
  real = { x = 705, y = 70, z = 600, f = 1 },
  home = { x = 705, y = 70, z = 600, f = 1 },
})

scenario("zweimal neu gestartet, dazwischen versetzt -> Heimplatz wandert nicht", {
  central = HOME,
  real = { x = 650, y = 90, z = 580, f = 1 },
  home = HOME,
  after = function(w, real)
    real.x, real.y, real.z, real.f = 600, 100, 550, 3 -- abgebaut und woanders hingestellt
    local nav = boot(w)
    eq(at(nav.home()), at(HOME), "nach 2. Start")
    eq(at(real), at(HOME), "wieder heimgeflogen")
    real.y = real.y + 30 -- nochmal versetzt, diesmal ohne Neustart: GPS-Kontrolle im Leerlauf
    local runner = require("jobrunner")
    local undo2 = select(2, realTurtle(w, false)) -- nur die Attrappen, Module bleiben geladen
    sim.advance((runner.GPS_CHECK + 1) * 1000)
    for _ = 1, 4 do sim.advance(16000) runner.step() end
    undo2()
    eq(at(nav.home()), at(HOME), "nach GPS-Kontrolle")
  end,
})

test("Szenario: Zentrale setzt den Heimplatz erst, waehrend die Turtle schon laeuft", function()
  local w = world()
  w.map:addZone("z", 0, 0, 0, 1000, 100, 1000)
  local real = { x = 650, y = 90, z = 580, f = 1 }
  local undo = physical(real)
  local ok, err = pcall(function()
    local nav = boot(w, 4)
    eq(nav.homeKnown(), false, "noch kein Heimplatz")
    w.map:setPlace("home:Miner1", HOME.x, HOME.y, HOME.z, HOME.f)
    local runner = require("jobrunner")
    local undo2 = select(2, realTurtle(w, false))
    turtle.getItemDetail = function() return nil end
    -- Kartenstand neu -> kommt beim naechsten Sync; dann soll sie gleich heim, nicht erst in 10 min
    for _ = 1, 6 do sim.advance(16000) runner.step() end
    undo2()
    eq(at(nav.home()), at(HOME))
    eq(at(real), at(HOME), "heimgeflogen")
  end)
  undo()
  assert(ok, err)
end)
