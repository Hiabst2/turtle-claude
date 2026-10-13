-- Tests fuer die Turtle-Seite von TurtleMQ (P1.3), werden von tests/run.lua geladen.
local sim = require("net")
local cc = require("cc")

-- Gateway und Turtle im simulierten Netz. Das Gateway "laeuft gleichzeitig": jedes Mal, wenn die Turtle
-- auf Funk wartet, dreht es eine Runde (wie die Schleife in gateway.lua).
local function setup(o)
  o = o or {}
  local net = sim.new(o.net)
  local gw = net.node(100, { names = { "gateway" }, accept = function() return true end })
  local b = require("broker").new(gw, { dir = "/gw" })
  local busy = false
  local function gwStep()
    if busy then return end
    busy = true
    b:step(0)
    busy = false
  end

  require("store").save("/.nav", { pos = { x = 725, y = 40, z = 630, f = 0 }, home = { x = 700, y = 64, z = 600, f = 0 }, gps = true })
  settings.values["mq.enabled"] = o.enabled ~= false
  settings.values["mq.interval"] = 60
  settings.values["claude.role"] = "turtle"
  cc.label = "Hiabst"

  local sync = require("sync")
  sync.now = sim.now
  -- Warten auf Funk wie im Spiel: die Zeit laeuft in 250-ms-Schritten, das Gateway arbeitet parallel.
  -- gatewayBusy: so viele Schritte reagiert das Gateway nicht (z.B. weil es gerade auf ein ACK wartet).
  local tlink = net.link()
  local receive = tlink.receive
  local state = { gatewayBusy = 0 }
  tlink.receive = function(t)
    local deadline = sim.clock + (t or 0) * 1000
    while true do
      if state.gatewayBusy > 0 then state.gatewayBusy = state.gatewayBusy - 1 else gwStep() end
      local packet = receive(0)
      if packet then return packet end
      if sim.clock >= deadline then return nil end
      sim.advance(250)
    end
  end
  -- ohne angelegtes Modem empfaengt die Turtle nichts
  tlink.down = true
  tlink.close = function() tlink.down = true end
  sync.linkFor = function()
    tlink.node = sync.getNode()
    tlink.down = false
    return tlink
  end
  sync.messages = {}
  sync.onMessage = function(m) sync.messages[#sync.messages + 1] = m end

  -- Modem liegt in Slot 2 und wird kurz statt der Spitzhacke angelegt
  local equips = 0
  turtle.getItemDetail = function(slot)
    if slot == 2 and o.modem ~= false then return { name = "computercraft:wireless_modem_advanced", count = 1 } end
  end
  turtle.getEquippedRight = function() return nil end
  turtle.equipLeft = function() equips = equips + 1 return true end
  local wrap = peripheral.wrap
  peripheral.wrap = function(side) if side == "left" then return { isWireless = function() return true end } end end

  return {
    sync = sync, gw = gw, b = b, gwStep = gwStep, net = net, state = state,
    equips = function() return equips end,
    done = function()
      peripheral.wrap = wrap
      turtle.getItemDetail = function() return nil end
      turtle.equipLeft = function() return true end
    end,
  }
end

test("Sync: Heartbeat kommt mit Position, Fuel und Version am Gateway an", function()
  local t = setup()
  local ok, text = t.sync.run()
  t.done()
  assert(ok, text)
  local d = t.b.state.devices[7]
  assert(d, "Turtle nicht beim Gateway bekannt")
  eq(d.label, "Hiabst") eq(d.role, "turtle") eq(d.fuel, 1000) eq(d.pos.x, 725) eq(d.pos.z, 630)
  assert(d.version, "Version fehlt")
  local line = t.b:statusLines()[1]
  assert(line:find("Hiabst") and line:find("online") and line:find("725 40 630"), line)
  eq(t.sync.getNode():pending(), 0, "Outbox leer")
  eq(t.equips(), 2, "Modem an und wieder ab")
end)

test("Sync: Post fuer die Turtle wird beim Sync abgeholt", function()
  local t = setup()
  local service = t.net.node(6)
  service:send(7, "job.assign", { area = "mine1" })
  service:flush()
  t.gwStep()
  eq(t.gw:pending(7), 1, "wartet im Postfach")
  t.sync.run()
  t.done()
  local found
  for _, m in ipairs(t.sync.messages) do if m.topic == "job.assign" then found = m end end
  assert(found, "Nachricht nicht angekommen")
  eq(found.payload.area, "mine1")
  eq(t.gw:pending(7), 0)
end)

test("Sync: ohne Modem bleibt nur der neueste Heartbeat in der Outbox", function()
  local t = setup({ modem = false })
  for _ = 1, 3 do
    local ok = t.sync.run()
    eq(ok, false)
    sim.advance(61000)
  end
  t.done()
  local beats = 0
  for _, m in ipairs(t.sync.getNode():list("outbox")) do
    if m.topic == "worker.heartbeat" then beats = beats + 1 end
  end
  eq(beats, 1)
  assert(t.sync.describe():find("kein Sync"), t.sync.describe())
end)

test("Sync: maybe haelt das Intervall ein, aus heisst aus", function()
  local t = setup()
  assert(t.sync.maybe(), "erster Sync")
  eq(t.sync.maybe(), false, "zu frueh")
  sim.advance(61000)
  assert(t.sync.maybe(), "Intervall um")
  settings.values["mq.enabled"] = false
  sim.advance(61000)
  eq(t.sync.maybe(), false)
  t.done()
  eq(t.sync.describe(), "TurtleMQ: aus")
end)

test("Sync: Auftrag mit Fortschritt im Heartbeat, danach wieder leer", function()
  local t = setup()
  settings.values["mq.interval"] = 0 -- jeder Schritt syncen
  require("zones").add("z", 700, 0, 600, 800, 100, 700)
  local mine = require("mine")
  local jobs = {}
  local route = t.b.route
  t.b.route = function(self, m)
    if m.topic == "worker.heartbeat" then jobs[#jobs + 1] = m.payload.job end
    return route(self, m)
  end
  local res = mine.run(mine.tunnel, { length = 2, width = 1, height = 1 }, function() end)
  t.done()
  assert(res:find("^Fertig"), res)
  local sawTunnel = false
  for _, j in ipairs(jobs) do if j and tostring(j):find("tunnel") then sawTunnel = true end end
  assert(sawTunnel, "kein Heartbeat mit Auftrag")
  eq(jobs[#jobs], false, "nach dem Auftrag kein Auftrag mehr")
  eq(t.b.state.devices[7].job, false)
end)

test("Sync: claude laeuft mit eingeschaltetem TurtleMQ, status zeigt die Zeile", function()
  settings.values["mq.enabled"] = true
  runClaude({ { "chat", "Hiabstla", "hiabst, status" } }, { toolUse("status"), text("ok") }, "Hiabstla")
  local res = lastMsg(cc.sent[2]).content[1].content
  assert(res:find("TurtleMQ: an"), res)
  assert(cc.chat[1] == "ok", tostring(cc.chat[1]))
end)

test("Sync: Gateway antwortet mit mq.done, die Turtle wartet nicht unnoetig", function()
  local t = setup()
  local before = sim.clock
  t.sync.run()
  t.done()
  eq(t.sync.getNode().done, true, "mq.done angekommen")
  assert(sim.clock - before < 2000, "Sync dauerte " .. (sim.clock - before) .. " ms")
end)

test("Sync: Post kommt auch an, wenn das Gateway gerade 3 s beschaeftigt ist", function()
  local t = setup()
  t.sync.run() -- anmelden (Sync-Geraet)
  local service = t.net.node(6)
  service:send(7, "job.assign", { area = "mine1" })
  service:flush()
  t.gwStep()
  sim.advance(61000)
  t.sync.messages = {}
  t.state.gatewayBusy = 12 -- 12 x 250 ms
  t.sync.run()
  t.done()
  local found = false
  for _, m in ipairs(t.sync.messages) do if m.topic == "job.assign" then found = true end end
  assert(found, "Post verpasst, obwohl das Gateway nur kurz beschaeftigt war")
  eq(t.gw:pending(7), 0)
end)

test("Sync: an Sync-Geraete keine Wiederholungen auf Verdacht, Ablauf trotzdem", function()
  local t = setup()
  t.sync.run() -- anmelden, Modus sync
  t.done()
  eq(t.b:isSync(7), true)
  local service = t.net.node(6)
  local sent = 0
  local transmit = t.gw.link.transmit
  t.gw.link.transmit = function(p)
    if p.target == 7 and p.topic == "job.assign" then sent = sent + 1 end
    return transmit(p)
  end
  service:send(7, "job.assign", {}, { ttl = 300 })
  service:flush()
  for _ = 1, 5 do
    t.gwStep()
    sim.advance(61000)
  end
  eq(sent, 0, "Gateway hat ins Leere gefunkt")
  eq(t.gw:pending(7), 1, "wartet im Postfach")
  sim.advance(300 * 1000)
  t.gwStep()
  eq(t.gw:pending(7), 0, "abgelaufene Post wird trotzdem verworfen")
end)

test("Flotte: Turtle fragt den Status aller Geraete ab, Antwort im selben Sync", function()
  local t = setup()
  local other = t.net.node(6)
  other:send("gateway", "worker.heartbeat", { label = "Miner2", role = "miner", fuel = 300,
    pos = { x = 1, y = 2, z = 3 }, job = "orehunt 1/4", interval = 60 })
  other:flush()
  t.gwStep()
  local reply, err = t.sync.ask("system.status")
  t.done()
  assert(reply, err)
  local byLabel = {}
  local names = {}
  for _, d in ipairs(reply.devices) do
    byLabel[d.label or ("#" .. d.id)] = d
    names[#names + 1] = tostring(d.label) .. "#" .. tostring(d.id)
  end
  assert(byLabel.Miner2 and byLabel.Hiabst, "Geraete fehlen: " .. table.concat(names, ", "))
  eq(byLabel.Miner2.role, "miner") eq(byLabel.Miner2.state, "online") eq(byLabel.Miner2.job, "orehunt 1/4")
  eq(byLabel.Miner2.pos.z, 3) eq(byLabel.Hiabst.fuel, 1000)
end)

test("Flotte: ohne TurtleMQ eine klare Meldung", function()
  local t = setup({ enabled = false })
  local reply, err = t.sync.ask("system.status")
  t.done()
  eq(reply, nil) assert(err:find("TurtleMQ ist aus"), err)
end)

test("Flotte: Gateway zeigt Rollen und warnt bei doppelten Namen", function()
  local t = setup()
  for _, id in ipairs({ 6, 8 }) do
    local n = t.net.node(id)
    n:send("gateway", "worker.heartbeat", { label = "Miner", role = "miner" })
    n:flush()
  end
  t.gwStep()
  t.done()
  local text = table.concat(t.b:statusLines(), "\n")
  assert(text:find("%[miner%]"), text)
  assert(text:find("Name doppelt"), text)
end)

test("Flotte: claude-Tool fleet zeigt die Geraete lesbar an", function()
  -- sync durch eine Attrappe ersetzen, damit nur das Tool selbst getestet wird
  package.loaded.sync = {
    enabled = function() return true end, interval = function() return 60 end, maybe = function() end,
    run = function() return true end, setJob = function() end, describe = function() return "TurtleMQ: an" end,
    ask = function(topic)
      assert(topic == "system.status")
      return { devices = { { id = 6, label = "Miner2", role = "miner", state = "online", seen_s = 12,
        pos = { x = 1, y = 2, z = 3 }, fuel = 300, job = "orehunt 1/4", mail = 2 } } }
    end,
  }
  runClaude({ { "chat", "Fremder", "hiabst, wie gehts den anderen?" } }, { toolUse("fleet"), text("ok") }, "Hiabstla")
  local res = lastMsg(cc.sent[2]).content[1].content
  assert(res:find("Miner2 %[miner%]: online, vor 12s bei 1 2 3, Fuel 300, orehunt 1/4, 2 Post wartet"), res)
end)
