-- Tests fuer die Leitstelle (Command-Node, P3.3), werden von tests/run.lua geladen.
local sim = require("net")
local cc = require("cc")

local function setup()
  local net = sim.new()
  local gw = net.node(100, { names = { "gateway" }, accept = function() return true end })
  local broker = require("broker").new(gw, { dir = "/gw" })
  local cnode = net.node(200, { dir = "/central/.mq" })
  local host = require("services").new(cnode, { label = "Zentrale" })
  local jobs = require("jobsvc").new(host, { dir = "/central" })
  host.add("job", jobs)
  local map = require("mapsvc").new(host, { dir = "/central" })
  host.add("map", map)
  host.add("path", require("pathsvc").new(host))
  local busy = false
  local function step()
    if busy then return end
    busy = true
    broker:step(0)
    host.step(0)
    busy = false
  end
  -- Warten auf Funk: Gateway und Zentrale arbeiten parallel, die Zeit laeuft
  local link = net.link()
  local receive = link.receive
  link.receive = function(t)
    local deadline = sim.clock + (t or 0) * 1000
    while true do
      step()
      local packet = receive(0)
      if packet then return packet end
      if sim.clock >= deadline then return nil end
      sim.advance(250)
    end
  end
  local node = require("mq").new({ id = 300, dir = "/cmd/.mq", link = link, now = sim.now, names = { "command" } })
  link.node = node
  local c = require("commander").new({ node = node, name = "Leitstelle", owner = "Hiabstla", key = "k",
    chatBox = cc.chatBox })
  c.start()
  step()
  return { c = c, jobs = jobs, map = map, net = net, step = step }
end

test("Leitstelle: Auftrag anlegen mit Startpunkt", function()
  local w = setup()
  local res = w.c.tools.job_create({ type = "tunnel", x = 710, y = 40, z = 610, facing = "sued", length = 20 })
  assert(res:find("J1 angelegt"), res)
  local j = w.jobs.state.jobs.J1
  eq(j.type, "tunnel") eq(j.params.length, 20) eq(j.params.start.x, 710) eq(j.params.start.f, 0)
end)

test("Leitstelle: Auftrag in einer Zone - Bereich und Start aus der Zone", function()
  local w = setup()
  w.map:addZone("mine1", 700, 0, 600, 750, 80, 650)
  w.map:setMaxY(50)
  local res = w.c.tools.job_create({ type = "orehunt", zone = "mine1", rounds = 2 })
  assert(res:find("angelegt"), res)
  local j = w.jobs.state.jobs.J1
  eq(j.area.x1, 700) eq(j.area.z2, 650)
  eq(j.params.start.x, 725) eq(j.params.start.z, 625)
  eq(j.params.start.y, 50, "oben in der Zone, aber unter dem Hoehenlimit")
  eq(j.params.rounds, 2)
  local bad = w.c.tools.job_create({ type = "orehunt", zone = "gibtsnicht" })
  assert(bad:find("keine Zone"), bad)
end)

test("Leitstelle: Auftraege auflisten und abbrechen", function()
  local w = setup()
  w.c.tools.job_create({ type = "tunnel", x = 1, y = 2, z = 3 })
  w.c.tools.job_create({ type = "gohome" })
  local list = w.c.tools.jobs_list({})
  assert(list:find("J1 tunnel: created") and list:find("J2 gohome: created"), list)
  local res = w.c.tools.job_cancel({ id = "J1" })
  eq(res, "J1 ist jetzt cancelled")
  eq(w.jobs.state.jobs.J1.state, "cancelled")
end)

test("Leitstelle: Flotte vom Gateway", function()
  local w = setup()
  local turtle = w.net.node(7)
  turtle:send("gateway", "worker.heartbeat", { label = "Miner1", role = "miner", fuel = 900, pos = { x = 1, y = 2, z = 3 } })
  turtle:flush()
  w.step()
  local res = w.c.tools.fleet()
  assert(res:find("Miner1 %[miner%]: online") and res:find("Fuel 900") and res:find("bei 1 2 3"), res)
  assert(res:find("Zentrale %[central%]: online"), "Zentrale sollte sich auch melden: " .. res)
end)

test("Leitstelle: Zonen aendern erst nach 'ja' des Besitzers", function()
  local w = setup()
  local a = w.c.agent
  cc.responses = { toolUse("map_change", { action = "zone_add", name = "mine2", x1 = 0, y1 = 0, z1 = 0,
    x2 = 10, y2 = 10, z2 = 10 }), text("Soll ich?") }
  a:handle("Hiabstla", "leg zone mine2 an", true)
  eq(#w.map.state.zones, 0, "noch nicht angelegt")
  assert(lastMsg(cc.sent[2]).content[1].content:find("NICHT ausgefuehrt"))

  a:enqueue("Fremder", "ja", true) -- fremdes "ja" zaehlt nicht
  cc.responses = { text("?") }
  a:step()
  eq(#w.map.state.zones, 0, "fremdes ja hat nichts geaendert")

  a:enqueue("Hiabstla", "ja", true)
  a:step()
  eq(#w.map.state.zones, 1, "nach dem ja des Besitzers angelegt")
  eq(w.map.state.zones[1].name, "mine2")
  local found = false
  for _, m in ipairs(cc.chat) do if m:find("Erledigt: Zone mine2") then found = true end end
  assert(found, "Bestaetigung im Chat fehlt")
end)

test("Leitstelle: Fremde duerfen fragen, aber keine Auftraege anlegen", function()
  local w = setup()
  local a = w.c.agent
  cc.responses = { toolUse("job_create", { type = "gohome" }), text("nein") }
  a:handle("Fremder", "schick alle heim", true)
  assert(lastMsg(cc.sent[2]).content[1].content:find("Nur Hiabstla"), "sollte abgelehnt werden")
  eq(w.jobs.state.next, 1, "kein Auftrag angelegt")
  cc.responses = { toolUse("jobs_list", {}), text("ok") }
  a:handle("Fremder", "was laeuft?", true)
  assert(lastMsg(cc.sent[4]).content[1].content:find("Keine aktuellen Auftraege"))
end)

test("Leitstelle: fertige und gescheiterte Auftraege werden von selbst gemeldet", function()
  local w = setup()
  local turtle = w.net.node(7)
  turtle:send("job", "job.complete", { id = "J1", epoch = 1, result = "Fertig. 12 Erzbloecke" })
  turtle:send("job", "job.fail", { id = "J2", epoch = 1, reason = "Lava", retry = true })
  turtle:flush()
  w.step()
  w.c.tick(1)
  local text = table.concat(cc.chat, " | ")
  assert(text:find("Auftrag J1 fertig") and text:find("12 Erzbloecke"), text)
  assert(text:find("Auftrag J2") and text:find("Lava") and text:find("erneut versucht"), text)
  eq(#w.c.agent.notes, 2, "Claude erfaehrt es mit der naechsten Nachricht")
end)

test("Leitstelle: Fehler in einem Tool zerstoert den Verlauf nicht", function()
  local w = setup()
  local a = w.c.agent
  w.c.tools.fleet = function() error("kaputt") end
  cc.responses = { toolUse("fleet", {}), text("ups") }
  a:handle("Hiabstla", "flotte?", true)
  local res = lastMsg(cc.sent[2]).content[1]
  eq(res.is_error, true) assert(res.content:find("kaputt"))
end)

test("Leitstelle: Fuel-Schaetzung ueber den Path-Dienst", function()
  local w = setup()
  local res = w.c.tools.fuel_estimate({ from = { x = 0, y = 20, z = 0 }, to = { x = 100, y = 64, z = 50 } })
  eq(res, "Etwa " .. require("cost").trip({ x = 0, y = 20, z = 0 }, { x = 100, y = 64, z = 50 }) .. " Fuel (Flug ueber Reisehoehe)")
end)
