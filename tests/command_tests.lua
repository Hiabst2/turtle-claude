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
  local busy, centralDown = false, false
  local function step()
    if busy then return end
    busy = true
    broker:step(0)
    if not centralDown then host.step(0) end
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
  return { c = c, jobs = jobs, map = map, net = net, step = step,
    centralDown = function(v) centralDown = v end }
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

-- R5 (docs/REVIEW-P3.md): die Leitstelle meldet, was die Zentrale entschieden hat - nicht die Worker-Nachricht
test("Leitstelle: meldet fertige und gescheiterte Auftraege nach dem Urteil der Zentrale", function()
  local w = setup()
  local turtle = w.net.node(7)
  local j1 = w.jobs:create({ type = "tunnel" }, "t")
  w.jobs:assign(j1, 7)
  local j2 = w.jobs:create({ type = "tunnel" }, "t")
  w.jobs:assign(j2, 7)
  turtle:send("job", "job.complete", { id = j1.id, epoch = 1, result = "Fertig. 12 Erzbloecke" })
  turtle:send("job", "job.complete", { id = j1.id, epoch = 1, result = "Fertig. 12 Erzbloecke" }) -- doppelt
  turtle:send("job", "job.fail", { id = j2.id, epoch = 1, reason = "Lava", retry = true })
  turtle:send("job", "job.complete", { id = "J99", epoch = 1, result = "Fertig. veraltet" }) -- unbekannt
  turtle:flush()
  for _ = 1, 3 do w.step() end
  w.c.tick(1)
  local text = table.concat(cc.chat, " | ")
  local _, n = text:gsub("Auftrag J1 fertig", "")
  eq(n, 1, "fertig genau einmal: " .. text)
  assert(text:find("12 Erzbloecke", 1, true), text)
  assert(text:find("Auftrag J2", 1, true) and text:find("Lava", 1, true) and text:find("erneut versucht", 1, true), text)
  assert(not text:find("veraltet", 1, true), "Meldung, die die Zentrale nicht angenommen hat: " .. text)
  eq(#w.c.agent.notes, 2, "Claude erfaehrt es mit der naechsten Nachricht")
end)

test("Leitstelle: Abbruch wird mit dem Zwischenstand der Turtle gemeldet", function()
  local w = setup()
  local turtle = w.net.node(7)
  local j = w.jobs:create({ type = "orehunt" }, "t")
  w.jobs:assign(j, 7)
  w.jobs:cancel(j.id)
  turtle:send("job", "job.fail", { id = j.id, epoch = 1, retry = false,
    reason = "Gestoppt: abgebrochen (Zentrale)\nBisher Abgebaut: 40 Bloecke, davon 9 Erz. Erze: iron x9" })
  turtle:flush()
  for _ = 1, 3 do w.step() end
  w.c.tick(1)
  local text = table.concat(cc.chat, " | ")
  assert(text:find("Auftrag J1 abgebrochen", 1, true) and text:find("iron x9", 1, true), text)
  assert(not text:find("Gestoppt: abgebrochen", 1, true), "ohne doppelten Vorspann: " .. text)
end)

-- R6: Wiederholung nach einem Timeout legt keinen zweiten Auftrag an
test("Leitstelle: job_create nach Timeout nochmal -> kein doppelter Auftrag", function()
  local w = setup()
  w.centralDown(true)
  local res1 = w.c.tools.job_create({ type = "tunnel", x = 710, y = 40, z = 610, length = 20 })
  assert(res1:find("antwortet nicht", 1, true), res1)
  w.centralDown(false)
  local res2 = w.c.tools.job_create({ type = "tunnel", x = 710, y = 40, z = 610, length = 20 })
  assert(res2:find("J1", 1, true), res2)
  for _ = 1, 3 do w.step() end
  local n = 0
  for _ in pairs(w.jobs.state.jobs) do n = n + 1 end
  eq(n, 1, "nur ein Auftrag")
end)

test("Leitstelle: zwei gewollt gleiche Auftraege bleiben zwei", function()
  local w = setup()
  local res1 = w.c.tools.job_create({ type = "tunnel", x = 710, y = 40, z = 610, length = 20 })
  local res2 = w.c.tools.job_create({ type = "tunnel", x = 710, y = 40, z = 610, length = 20 })
  assert(res1:find("J1", 1, true), res1)
  assert(res2:find("J2", 1, true), res2)
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

-- Verlauf nur hinten ergaenzen (Whitepaper 6.2) --------------------------------------
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
-- beginnt der Verlauf von req2 exakt mit dem von req1?
local function extends(req1, req2)
  if #req2.messages < #req1.messages then return false end
  for i, m in ipairs(req1.messages) do
    if not same(m, req2.messages[i]) then return false end
  end
  return true
end

test("Leitstelle: Verlauf wird nur hinten ergaenzt, Modell und Effort stimmen", function()
  local w = setup()
  local a = w.c.agent
  cc.responses = { toolUse("jobs_list", {}), text("nichts los"), toolUse("fleet", {}), text("alle da"), text("gern") }
  a:handle("Hiabstla", "was laeuft?", true)
  a:handle("Hiabstla", "und die turtles?", true)
  a:handle("Hiabstla", "danke", true)
  eq(#cc.sent, 5)
  for i = 2, #cc.sent do assert(extends(cc.sent[i - 1], cc.sent[i]), "Verlauf veraendert vor Aufruf " .. i) end
  eq(cc.sent[1].model, "claude-opus-5-5")
  eq(cc.sent[1].output_config.effort, "low")
  assert(cc.sent[1].messages[1].content:find("Neue Sitzung"), "Lagemeldung am Anfang fehlt")
end)

test("Leitstelle: voller Verlauf -> neue Sitzung mit Lagemeldung statt abgeschnittenem Verlauf", function()
  local w = setup()
  require("agent").SESSION_MESSAGES = 4
  local a = w.c.agent
  w.c.tools.job_create({ type = "gohome" })
  cc.responses = { text("a"), text("b"), text("c") }
  a:handle("Hiabstla", "eins", true)
  a:handle("Hiabstla", "zwei", true)
  a:handle("Hiabstla", "drei", true)
  assert(extends(cc.sent[1], cc.sent[2]), "zweite Frage: gleiche Sitzung")
  eq(#cc.sent[3].messages, 1, "neue Sitzung beginnt leer")
  local first = cc.sent[3].messages[1].content
  assert(first:find("Neue Sitzung") and first:find("J1 gohome") and first:find("drei"), first)
end)

test("Leitstelle: nach langer Pause neue Sitzung", function()
  local w = setup()
  local a = w.c.agent
  local t = 0
  a.now = function() return t end
  cc.responses = { text("a"), text("b"), text("c") }
  a:handle("Hiabstla", "eins", true)
  t = 60 * 1000
  a:handle("Hiabstla", "zwei", true)
  assert(extends(cc.sent[1], cc.sent[2]), "kurze Pause: gleiche Sitzung")
  t = t + (require("agent").SESSION_IDLE + 1) * 1000
  a:handle("Hiabstla", "drei", true)
  eq(#cc.sent[3].messages, 1, "nach langer Pause neue Sitzung")
end)

test("Leitstelle: Ablehnung wird gemeldet und landet nicht im Verlauf", function()
  local w = setup()
  local a = w.c.agent
  cc.responses = { { type = "message", stop_reason = "refusal", stop_details = { category = "cyber" }, content = {} },
    text("ok") }
  a:handle("Hiabstla", "boese frage", true)
  local said = table.concat(cc.chat, " | ")
  assert(said:find("abgelehnt: cyber"), said)
  a:handle("Hiabstla", "normale frage", true)
  for _, m in ipairs(cc.sent[2].messages) do assert(m.role ~= "assistant", "abgelehnte Antwort im Verlauf") end
  assert(extends(cc.sent[1], cc.sent[2]), "Verlauf nach Ablehnung veraendert")
end)

test("Leitstelle: lange Tool-Ergebnisse werden gekuerzt", function()
  local w = setup()
  local a = w.c.agent
  w.c.tools.fleet = function() return ("x"):rep(5000) end
  cc.responses = { toolUse("fleet", {}), text("viel") }
  a:handle("Hiabstla", "flotte?", true)
  local res = lastMsg(cc.sent[2]).content[1].content
  assert(#res < 2100 and res:find("gekuerzt, 5000 Zeichen", 1, true), "Laenge " .. #res)
end)
