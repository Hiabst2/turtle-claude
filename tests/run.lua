-- Tests ausserhalb von Minecraft:  cd turtle-claude && lua5.2 tests/run.lua
-- Module liegen im Repository in Ordnern (auf dem Geraet flach, siehe update.lua); Programme in apps/ und bin/
package.path = "./?.lua;./core/?.lua;./turtle/?.lua;./net/?.lua;./central/?.lua;./claude/?.lua;./tests/?.lua;" .. package.path
local say = function(s) io.write(s, "\n") end -- print ist durch die CC-Attrappe belegt
local cc = require("cc")

local MODULES = { "store", "zones", "gear", "nav", "path", "mine", "colony", "mq", "version", "broker", "sync", "crypto", "services", "jobsvc", "jobrunner", "cost", "mapsvc", "pathsvc", "agent", "commander" }
local function fresh()
  cc.reset()
  for _, m in ipairs(MODULES) do package.loaded[m] = nil end
  cc.sent, cc.responses, cc.chat, cc.out, cc.events = {}, {}, {}, {}, {}
  cc.web, cc.gets = {}, {}
  settings.values = {}
end

local passed, failed = 0, 0
local function test(name, fn)
  if _G.ONLY and not name:find(_G.ONLY) then return end -- nur ausgewaehlte Tests: lua5.2 -e 'ONLY="Worker"' tests/run.lua
  fresh()
  -- in einer Koroutine, weil CC-Code zwischendurch os.pullEvent aufruft (z.B. die Wegsuche zum Durchatmen)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  while ok and coroutine.status(co) == "suspended" do ok, err = coroutine.resume(co) end
  if ok then passed = passed + 1 say("ok    " .. name)
  else failed = failed + 1 say("FAIL  " .. name .. "\n      " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " erwartet " .. tostring(b) .. ", war " .. tostring(a), 2) end end

-- B4 -------------------------------------------------------------------
test("store: speichern und laden", function()
  local store = require("store")
  store.save("/.x", { a = 1 })
  eq(store.load("/.x").a, 1)
  store.save("/.x", { a = 2 })
  eq(store.load("/.x").a, 2)
  eq(textutils.unserialize(cc.readFile("/.x.bak")).a, 1, "Sicherung")
end)

test("store: kaputte Datei -> Sicherung", function()
  local store = require("store")
  store.save("/.x", { a = 1 })
  store.save("/.x", { a = 2 })
  cc.writeFile("/.x", "{ kaputt")
  local t, err, fromBackup = store.load("/.x")
  eq(t.a, 1) eq(err, nil) eq(fromBackup, true)
end)

test("store: alles kaputt -> corrupt, nie da -> missing", function()
  local store = require("store")
  local t, err = store.load("/.nie")
  eq(t, nil) eq(err, "missing")
  cc.writeFile("/.y", "{ kaputt")
  t, err = store.load("/.y")
  eq(t, nil) eq(err, "corrupt")
end)

test("nav: kaputte Positionsdatei -> nicht still 0,0,0, Heimweg gesperrt", function()
  cc.writeFile("/.nav", "{ kaputt")
  local nav = require("nav")
  assert(nav.where():find("ACHTUNG"), "Warnung fehlt in where()")
  eq(nav.hasGps(), false, "GPS-Flag")
  local ok, err = nav.goHome()
  eq(ok, false) assert(err:find("Heimplatz unbekannt"))
  nav.setHome()
  assert(not nav.where():find("ACHTUNG"), "Warnung nach sethome noch da")
end)

test("nav: normale Positionsdatei bleibt erhalten", function()
  local store = require("store")
  store.save("/.nav", { pos = { x = 5, y = 6, z = 7, f = 1 }, home = { x = 1, y = 2, z = 3, f = 0 }, gps = true })
  local nav = require("nav")
  eq(nav.pos().x, 5) eq(nav.home().z, 3) eq(nav.hasGps(), true)
end)

test("zones: kaputte Zonendatei -> keine Zonen, also kein Graben", function()
  cc.writeFile("/.zones", "{ kaputt")
  local zones = require("zones")
  local ok = zones.check({ x = 0, y = 0, z = 0 }, "minecraft:stone", true)
  eq(ok, false)
end)

-- B2 -------------------------------------------------------------------
test("nav.tripCost: kurze Wege direkt, weite ueber Reisehoehe", function()
  local nav = require("nav")
  nav.TRAVEL_Y = 110
  eq(nav.tripCost({ x = 0, y = 20, z = 0 }, { x = 5, y = 20, z = 3 }), 8)
  -- 90 hoch, 100 + 50 rueber, 46 runter
  eq(nav.tripCost({ x = 0, y = 20, z = 0 }, { x = 100, y = 64, z = 50 }), 90 + 150 + 46)
  -- schon ueber Reisehoehe: nicht erst runter
  eq(nav.tripCost({ x = 0, y = 130, z = 0 }, { x = 100, y = 64, z = 0 }), 0 + 100 + 66)
end)

-- B1 / B3: claude.lua mit vorbereiteten API-Antworten --------------------
local function runClaude(events, responses, owner)
  cc.label = "Hiabst"
  settings.values["claude.key"] = "test"
  settings.values["claude.owner"] = owner
  cc.peripherals.chatBox = cc.chatBox
  cc.responses = responses
  cc.events = events
  dofile("apps/claude.lua")
end

local function toolUse(name, input, stop)
  return { type = "message", stop_reason = stop or "tool_use",
    content = { { type = "tool_use", id = "t1", name = name, input = input or {} } } }
end
local function text(t) return { type = "message", stop_reason = "end_turn", content = { { type = "text", text = t } } } end
local function lastMsg(req) return req.messages[#req.messages] end

test("B1: Lua-Fehler im Tool wird zum Fehler-Ergebnis statt den Verlauf zu zerstoeren", function()
  turtle.getItemDetail = function() error("Detektor kaputt") end
  runClaude({ { "chat", "Hiabstla", "hiabst, status?" } }, { toolUse("status"), text("ok") }, "Hiabstla")
  turtle.getItemDetail = function() return nil end
  eq(#cc.sent, 2, "Anzahl API-Aufrufe")
  local res = lastMsg(cc.sent[2]).content[1]
  eq(res.type, "tool_result") eq(res.tool_use_id, "t1") eq(res.is_error, true)
  assert(res.content:find("Detektor kaputt"), res.content)
end)

test("B1: tool_use bei end_turn bekommt trotzdem sein Ergebnis", function()
  runClaude({ { "chat", "Hiabstla", "hiabst, eins" }, { "chat", "Hiabstla", "hiabst, zwei" } },
    { toolUse("status", nil, "end_turn"), text("ok") }, "Hiabstla")
  local msgs = cc.sent[2].messages
  eq(msgs[2].role, "assistant")
  eq(msgs[3].role, "user") eq(msgs[3].content[1].type, "tool_result")
end)

test("B3: fremder Spieler darf nicht steuern, aber fragen", function()
  runClaude({ { "chat", "Fremder", "hiabst, fahr heim" } },
    { toolUse("go_home"), toolUse("status"), text("ok") }, "Hiabstla")
  local denied = lastMsg(cc.sent[2]).content[1].content
  assert(denied:find("Nur Hiabstla"), denied)
  local allowed = lastMsg(cc.sent[3]).content[1].content
  assert(allowed:find("Fuel"), "status sollte erlaubt sein: " .. allowed)
end)

test("B3: Besitzer darf steuern", function()
  runClaude({ { "chat", "hiabstla", "hiabst, setz den heimplatz" } }, { toolUse("set_home"), text("ok") }, "Hiabstla")
  local res = lastMsg(cc.sent[2]).content[1].content
  assert(res:find("Heimplatz gesetzt"), res)
end)

test("B3: ohne Besitzer darf per Chat niemand steuern", function()
  runClaude({ { "chat", "Hiabstla", "hiabst, setz den heimplatz" } }, { toolUse("set_home"), text("ok") }, nil)
  local res = lastMsg(cc.sent[2]).content[1].content
  assert(res:find("kein Besitzer"), res)
end)

-- Block 2 ---------------------------------------------------------------
test("B6: lange Chat-Antworten am Leerzeichen und nie mitten in UTF-8 teilen", function()
  local long = ("Grüße aus der Mine, ich habe viel Eisenerz gefunden. "):rep(8)
  runClaude({ { "chat", "Hiabstla", "hiabst, erzaehl" } }, { text(long) }, "Hiabstla")
  assert(#cc.chat >= 2, "sollte geteilt werden")
  for _, part in ipairs(cc.chat) do
    assert(#part <= 240, "zu lang: " .. #part)
    local first = part:byte(1)
    assert(not (first >= 0x80 and first <= 0xBF), "Teil beginnt mitten in einem UTF-8-Zeichen")
    assert(not part:find("^%s"), "Teil beginnt mit Leerzeichen")
  end
  eq(table.concat(cc.chat, " "), (long:gsub("%s+$", "")), "Text unvollstaendig")
end)

test("B6: ohne Leerzeichen wird trotzdem nicht in UTF-8 geschnitten", function()
  local long = ("äöü"):rep(100)
  runClaude({ { "chat", "Hiabstla", "hiabst, x" } }, { text(long) }, "Hiabstla")
  for _, part in ipairs(cc.chat) do
    local first = part:byte(1)
    assert(not (first >= 0x80 and first <= 0xBF), "Teil beginnt mitten in einem UTF-8-Zeichen")
  end
  eq(table.concat(cc.chat), long)
end)

test("B7: bei 529 und Timeout wird wiederholt", function()
  cc.posts = 0
  runClaude({ { "chat", "Hiabstla", "hiabst, hallo" } }, { { fail = 529 }, { fail = "timeout" }, text("da") }, "Hiabstla")
  eq(cc.posts, 3, "Versuche")
  eq(cc.chat[1], "da")
end)

test("B7: bei 400 wird nicht wiederholt", function()
  cc.posts = 0
  runClaude({ { "chat", "Hiabstla", "hiabst, hallo" } }, { { fail = 400 }, text("nie") }, "Hiabstla")
  eq(cc.posts, 1, "Versuche")
  assert(cc.chat[1]:find("API%-Fehler"), cc.chat[1])
end)

test("B10: Hiabstxyz spricht die Turtle nicht an, Hiabst? schon", function()
  runClaude({ { "chat", "Hiabstla", "hiabstxyz, status" }, { "chat", "Hiabstla", "Hiabst? status" } },
    { text("ja?") }, "Hiabstla")
  eq(#cc.sent, 1, "nur die zweite Nachricht")
  assert(lastMsg(cc.sent[1]).content:find("status"))
end)

-- B8 / P0.6: update nach Rolle, vom selben Commit, atomar ----------------
local SHA = "abc1234def5678"
local function web(files, sha)
  cc.web = {}
  if sha then cc.web["api:main"] = { sha = sha } end
  for name, body in pairs(files) do cc.web[(sha or "main") .. "/" .. name] = body end
end

test("B8: update laedt alle Dateien vom selben Commit und merkt sich die Version", function()
  web({ ["roles/turtle.txt"] = "# Kommentar\nnav.lua\nupdate.lua\n", ["nav.lua"] = "neu", ["update.lua"] = "-- u" }, SHA)
  dofile("update.lua")
  eq(cc.readFile("/nav.lua"), "neu")
  for _, url in ipairs(cc.gets) do
    if url:find("raw.githubusercontent", 1, true) then assert(url:find(SHA, 1, true), "nicht vom Commit: " .. url) end
  end
  local v = textutils.unserialize(cc.readFile("/.version"))
  eq(v.sha, SHA) eq(v.role, "turtle") eq(v.channel, "main") eq(#v.files, 2)
  package.loaded.version = nil
  assert(require("version").text():find("abc1234 %(main, turtle%)"), require("version").text())
end)

test("B8: abgebrochener Download ersetzt nichts", function()
  cc.writeFile("/nav.lua", "alt")
  web({ ["roles/turtle.txt"] = "nav.lua\nfehlt.lua\n", ["nav.lua"] = "neu" }, SHA)
  dofile("update.lua")
  eq(cc.readFile("/nav.lua"), "alt")
  eq(fs.exists("/.update"), false, "Temp-Verzeichnis aufgeraeumt")
  eq(fs.exists("/.version"), false)
end)

test("B8: schon aktuell -> nichts laden", function()
  web({ ["roles/turtle.txt"] = "nav.lua\n", ["nav.lua"] = "neu" }, SHA)
  dofile("update.lua")
  cc.gets = {}
  dofile("update.lua")
  eq(#cc.gets, 1, "nur die API-Abfrage")
end)

test("B8: ohne API (Limit) wird vom Branch geladen", function()
  web({ ["roles/turtle.txt"] = "nav.lua\n", ["nav.lua"] = "neu" }, nil)
  dofile("update.lua")
  eq(cc.readFile("/nav.lua"), "neu")
end)

test("B8: Kanal und Rolle waehlen Branch und Manifest", function()
  settings.values["claude.channel"] = "beta"
  settings.values["claude.role"] = "miner"
  cc.web = { ["api:beta"] = { sha = SHA }, [SHA .. "/roles/miner.txt"] = "nav.lua\n", [SHA .. "/nav.lua"] = "x" }
  dofile("update.lua")
  eq(cc.readFile("/nav.lua"), "x")
  assert(cc.gets[1]:find("commits/beta$"), cc.gets[1])
end)

test("P0.6: Rollenwechsel raeumt Dateien der alten Rolle weg", function()
  web({ ["roles/turtle.txt"] = "nav.lua\nclaude.lua\n", ["nav.lua"] = "n", ["claude.lua"] = "c" }, SHA)
  dofile("update.lua")
  eq(cc.readFile("/claude.lua"), "c")
  settings.values["claude.role"] = "miner"
  web({ ["roles/miner.txt"] = "nav.lua\n", ["nav.lua"] = "n2" }, "fff0000111")
  dofile("update.lua")
  eq(fs.exists("/claude.lua"), false, "claude.lua gehoert nicht zum Miner")
  eq(cc.readFile("/nav.lua"), "n2")
end)

test("P0.6: bootstrap richtet Rolle und Kanal ein und installiert", function()
  turtle = turtle or {}
  cc.web = {
    ["main/update.lua"] = assert(io.open("update.lua")):read("*a"),
    ["api:main"] = { sha = SHA },
    [SHA .. "/roles/miner.txt"] = "nav.lua\n",
    [SHA .. "/nav.lua"] = "n",
  }
  loadfile("bootstrap.lua")("miner")
  eq(settings.values["claude.role"], "miner")
  eq(settings.values["claude.channel"], "main")
  eq(cc.readFile("/nav.lua"), "n")
end)

test("P0.6: Rollenlisten passen zum Repository", function()
  local function lines(file)
    local t = {}
    for l in io.lines(file) do if not l:match("^%s*#") and l ~= "" then t[#t + 1] = l end end
    return t
  end
  for _, role in ipairs({ "turtle", "miner", "gps", "gateway", "central", "command" }) do
    local names = {}
    for _, path in ipairs(lines("roles/" .. role .. ".txt")) do
      assert(io.open(path), role .. ": Datei fehlt im Repository: " .. path)
      -- auf dem Geraet landen alle Dateien flach: kein Name darf doppelt vorkommen
      local name = path:match("[^/]+$")
      assert(not names[name], role .. ": Dateiname doppelt: " .. name)
      names[name] = true
    end
    -- Altlast fuer aeltere update-Versionen: holt nur das neue update und startup
    eq(table.concat(lines("manifests/" .. role .. ".txt"), ","), "update.lua,startup.lua", "manifests/" .. role)
  end
  eq(table.concat(lines("files.txt"), ","), "update.lua,startup.lua", "files.txt")
end)

test("Ordner: Dateien aus Unterordnern landen flach, alter Stand ohne layout wird neu geladen", function()
  -- Stand nach einem alten update: gleicher Commit, aber ohne layout und nur update/startup
  cc.writeFile("/.version", textutils.serialize({ sha = SHA, role = "turtle", channel = "main",
    files = { "update.lua", "startup.lua" } }))
  web({ ["roles/turtle.txt"] = "turtle/nav.lua\ncore/store.lua\n", ["turtle/nav.lua"] = "n",
    ["core/store.lua"] = "s" }, SHA)
  dofile("update.lua")
  eq(cc.readFile("/nav.lua"), "n", "trotz gleichem Commit neu geladen")
  eq(cc.readFile("/store.lua"), "s")
  eq(fs.exists("/turtle/nav.lua"), false, "kein Unterordner auf dem Geraet")
  local v = textutils.unserialize(cc.readFile("/.version"))
  eq(v.layout, 2) eq(v.files[1], "nav.lua")
end)

test("Ordner: zwei Dateien mit gleichem Namen -> Update bricht ab, nichts geaendert", function()
  cc.writeFile("/nav.lua", "alt")
  web({ ["roles/turtle.txt"] = "turtle/nav.lua\nbin/nav.lua\n", ["turtle/nav.lua"] = "a", ["bin/nav.lua"] = "b" }, SHA)
  dofile("update.lua")
  eq(cc.readFile("/nav.lua"), "alt")
  eq(fs.exists("/.version"), false)
end)

-- Lesbarkeit im Spiel: der Turtle-Bildschirm ist 39 Zeichen breit. Laengere Zeilen bricht CC um,
-- dann rutscht die Einrichtung auf 13 Zeilen schnell aus dem Bild.
local SCREEN = 39
local function checkWidth(what)
  for _, entry in ipairs(cc.out) do
    for line in (entry .. "\n"):gmatch("(.-)\n") do
      assert(#line <= SCREEN, ("%s: Zeile zu lang (%d Zeichen): %s"):format(what, #line, line))
    end
  end
end

test("Bildschirm: bootstrap und update passen auf die Turtle, leere Eingaben gehen", function()
  local realRead, realSet, realTurtle = read, settings.set, turtle
  -- wie in CC: settings.set lehnt nil ab (R4)
  settings.set = function(k, v) assert(v ~= nil, "settings.set mit nil: " .. k) realSet(k, v) end
  local ok, err = pcall(function()
    -- Rolle -> Antworten der Reihe nach (leer = Enter)
    local CASES = {
      { role = "miner", turtle = true, answers = { "", "", "", "" } }, -- Rolle per Vorgabe (miner)
      { role = "turtle", turtle = true, answers = { "turtle", "", "", "", "", "" } },
      { role = "gateway", answers = { "gateway", "", "" } },
      { role = "central", answers = { "central", "", "" } },
      { role = "command", answers = { "command", "", "", "", "", "" } },
      { role = "gps", answers = { "", "", "1", "2", "3" } }, -- Rolle per Vorgabe (gps)
    }
    for _, case in ipairs(CASES) do
      cc.reset()
      cc.out, settings.values, cc.label = {}, {}, nil
      turtle = case.turtle and realTurtle or nil
      local answers = case.answers
      read = function() return table.remove(answers, 1) or "" end
      cc.web = {
        ["main/update.lua"] = assert(io.open("update.lua")):read("*a"),
        ["api:main"] = { sha = SHA },
        [SHA .. "/roles/" .. case.role .. ".txt"] = "core/version.lua\n",
        [SHA .. "/core/version.lua"] = "-- v",
      }
      loadfile("bootstrap.lua")()
      eq(settings.values["claude.role"], case.role, "Rolle")
      eq(cc.readFile("/version.lua"), "-- v", case.role .. ": installiert")
      -- nochmal update: "schon aktuell" muss auch passen
      dofile("update.lua")
      checkWidth("bootstrap " .. case.role)
    end
  end)
  read, settings.set, turtle = realRead, realSet, realTurtle
  assert(ok, err)
end)

test("Bildschirm: Worker passt auf die Turtle (39x13), auch mit langen Meldungen", function()
  local screen = require("screen")
  settings.values["mq.enabled"] = true
  cc.label = "Miner-mit-sehr-langem-Namen-1234567890"
  local runner = require("jobrunner")
  runner.init()
  runner.setPrinter(function() end)
  runner.say(("Heimweg gescheitert: Darf hier nicht graben, x=1 y=2 z=3 liegt in keiner Zone. "):rep(3))
  require("sync").onMessage({ topic = "job.none", payload = { reasons = ("J1: fehlt geo_scanner, chest; "):rep(6) } })
  local s = screen.new(39, 13)
  screen.run(s, runner.draw)
  eq(s.scrolled, 0, "aus dem Bild gescrollt\n" .. s.dump())
  eq(s.clipped, 0, "abgeschnitten\n" .. s.dump())
  assert(s.line(1):find("^Worker"), s.dump())
  eq(s.line(13), runner.HELP, "Tastenhilfe unten\n" .. s.dump())
  assert(s.dump():find("Kein passender") and s.dump():find("Zuletzt"), s.dump())
end)

test("Bildschirm: Gateway passt auf den Computer (51x19), auch mit vielen Geraeten", function()
  local screen = require("screen")
  local node = { id = 1, rejected = 2, lastRejected = 99, now = function() return 10 ^ 9 end,
    pending = function() return 3 end, list = function() return { {} } end }
  local b = require("broker").new(node, { dir = "/.gw" })
  for i = 1, 25 do
    b.state.devices[i] = { id = i, label = "Turtle-mit-langem-Namen-" .. i, role = "miner", interval = 60,
      last_seen = 10 ^ 9 - 5000, pos = { x = -12345, y = 64, z = 67890 }, fuel = 99999,
      job = "J" .. i .. " orehunt 3/4 Nachscan 2" }
  end
  for i = 1, 8 do b.log[i] = { source = i, target = "gateway", topic = "worker.heartbeat" } end
  local s = screen.new(51, 19)
  screen.run(s, function() b:draw(4242) end)
  eq(s.scrolled, 0, "aus dem Bild gescrollt\n" .. s.dump())
  eq(s.clipped, 0, "abgeschnitten\n" .. s.dump())
  assert(s.line(1):find("^TurtleMQ Gateway"), s.dump())
  assert(s.dump():find("weitere Geraete"), "Hinweis auf weitere Geraete fehlt\n" .. s.dump())
  eq(s.line(14), ("-"):rep(51), "Trennlinie ueber den letzten 5 Nachrichten\n" .. s.dump())
end)

test("Rollen: jede Rolle bekommt alle Module, die ihre Dateien laden", function()
  local function lines(file)
    local t = {}
    for l in io.lines(file) do if not l:match("^%s*#") and l ~= "" then t[#t + 1] = l end end
    return t
  end
  -- startup/update/bootstrap laufen in jeder Rolle und laden rollenabhaengig, die zaehlen hier nicht
  local SKIP = { ["startup.lua"] = true, ["update.lua"] = true, ["bootstrap.lua"] = true }
  for _, role in ipairs({ "turtle", "miner", "gps", "gateway", "central", "command" }) do
    local have, paths = {}, lines("roles/" .. role .. ".txt")
    for _, path in ipairs(paths) do have[path:match("[^/]+$")] = true end
    for _, path in ipairs(paths) do
      if not SKIP[path] then
        local f = assert(io.open(path))
        local code = f:read("*a")
        f:close()
        for name in code:gmatch('require%("([%w_]+)"%)') do
          assert(have[name .. ".lua"], ("%s: %s braucht %s.lua, fehlt in roles/%s.txt"):format(role, path, name, role))
        end
      end
    end
  end
end)

test("B9: nextOre sucht nur rund um den aktuellen Scan", function()
  local store = require("store")
  store.save("/.nav", { pos = { x = 0, y = 0, z = 0, f = 0 }, home = { x = 0, y = 0, z = 0, f = 0 }, gps = true })
  require("zones").add("test", -100, -100, -100, 100, 100, 100)
  local path = require("path")
  local map = path.newMap()
  path.markAir(map, { x = 0, y = 0, z = 0 })
  path.set(map, 50, 0, 0, "ore", "minecraft:iron_ore") -- weit weg
  eq(path.nextOre(map, nil, { x = 0, y = 0, z = 0 }, 8), false, "weit entferntes Erz gehoert nicht zu diesem Scan")
  path.set(map, 3, 0, 0, "ore", "minecraft:iron_ore")
  local found
  eq(path.nextOre(map, function(n) found = n end, { x = 0, y = 0, z = 0 }, 8), true)
  eq(found, "minecraft:iron_ore")
  eq(require("nav").pos().x, 3)
end)

-- R14: Kosten bilden die Zeit ab, nicht den abgebauten Stein
test("R14: Wegsuche graebt sich durch 3 Stein statt 10 Bloecke Umweg durch Luft", function()
  local store = require("store")
  store.save("/.nav", { pos = { x = 0, y = 0, z = 0, f = 3 }, home = { x = 0, y = 0, z = 0, f = 0 }, gps = true })
  require("zones").add("test", -100, -100, -100, 100, 100, 100)
  local path = require("path")
  local map = path.newMap()
  path.markAir(map, { x = 0, y = 0, z = 0 })
  for x = 1, 3 do path.set(map, x, 0, 0, "solid", "minecraft:stone") end
  path.set(map, 4, 0, 0, "air")
  -- Umweg durch eine Hoehle: 3 hoch, 4 rueber, 3 runter = 10 Schritte
  for _, c in ipairs({ { 0, 1 }, { 0, 2 }, { 0, 3 }, { 1, 3 }, { 2, 3 }, { 3, 3 }, { 4, 3 }, { 4, 2 }, { 4, 1 } }) do
    path.set(map, c[1], c[2], 0, "air")
  end
  eq(path.stepsTo(map, { x = 4, y = 0, z = 0 }), 4, "direkt durch den Stein (Kosten 7 statt 10)")
end)

-- R15: der echte Rueckweg zaehlt, nicht die Luftlinie
test("R15: Fuel-Pruefung erkennt einen Rueckweg, der dreimal so lang ist wie die Luftlinie", function()
  local store = require("store")
  store.save("/.nav", { pos = { x = 10, y = 0, z = 0, f = 3 }, home = { x = 0, y = 0, z = 0, f = 0 }, gps = true })
  -- erlaubt ist nur ein U: von 10,0,0 nach 10,0,10, rueber nach 0,0,10, zurueck nach 0,0,0 (30 Schritte)
  local zones = require("zones")
  zones.add("a", 0, 0, 0, 0, 0, 10)
  zones.add("b", 0, 0, 10, 10, 0, 10)
  zones.add("c", 10, 0, 0, 10, 0, 10)
  local path = require("path")
  local mine = require("mine")
  local map = path.newMap()
  path.markAir(map, { x = 10, y = 0, z = 0 })
  path.markAir(map, { x = 0, y = 0, z = 10 })
  path.markAir(map, { x = 10, y = 0, z = 10 })
  eq(path.stepsTo(map, { x = 0, y = 0, z = 0 }), 30)

  local said = {}
  local ctx = { start = { x = 0, y = 0, z = 0, f = 0 }, map = map, order = "xzy", junk = true, ores = {},
    say = function(t) said[#said + 1] = t end }
  local realFuel = turtle.getFuelLevel
  local ok = pcall(function()
    -- reichlich Fuel: keine Lagerfahrt
    turtle.getFuelLevel = function() return 1000 end
    mine.maintain(ctx)
    eq(#said, 0, "bei vollem Tank keine Lagerfahrt")
    -- Luftlinie (10) + Reserve (200) = 210 wuerde reichen, der echte Weg (30) + 200 = 230 nicht
    turtle.getFuelLevel = function() return 220 end
    pcall(mine.maintain, ctx) -- die Lagerfahrt scheitert hier (kein Lager aufgebaut), es zaehlt die Entscheidung
  end)
  turtle.getFuelLevel = realFuel
  assert(ok)
  assert(said[1] and said[1]:find("Fuel wird knapp"), "Lagerfahrt fehlt: " .. tostring(said[1]))
end)

-- R17: Beute behalten statt Junk-Liste; Ausnahmen je Auftrag
test("R17: nur Beute bleibt im Inventar, Auftraege koennen Ausnahmen machen", function()
  local nav = require("nav")
  local inv, sel = {}, 1
  local function fill()
    inv = {
      [1] = { name = "minecraft:cobblestone", count = 64 },
      [2] = { name = "minecraft:raw_iron", count = 5, tags = { ["c:raw_materials/iron"] = true } },
      [3] = { name = "create:limestone", count = 12 }, -- Gestein aus einem Mod
      [4] = { name = "mekanism:fluorite_gem", count = 3, tags = { ["c:gems/fluorite"] = true } },
      [5] = { name = "minecraft:coal", count = 10 },
      [6] = { name = "minecraft:diamond_pickaxe", count = 1 },
      [7] = { name = "minecraft:amethyst_block", count = 2 },
      [8] = { name = "minecraft:redstone", count = 9, tags = { ["c:dusts/redstone"] = true } },
    }
  end
  local function left()
    local t = {}
    for s = 1, 16 do if inv[s] then t[#t + 1] = s end end
    return table.concat(t, ",")
  end
  local real = { turtle.getItemDetail, turtle.select, turtle.dropUp }
  turtle.getItemDetail = function(s) return inv[s] end
  turtle.select = function(s) sel = s return true end
  turtle.dropUp = function() inv[sel] = nil return true end
  local ok, err = pcall(function()
    fill() nav.dropJunk()
    eq(left(), "2,4,5,6,8", "Standard: Beute, Kohle, Ausruestung")
    fill() nav.dropJunk({ keep = { "amethyst" } })
    eq(left(), "2,4,5,6,7,8", "keep: Amethyst zusaetzlich")
    fill() nav.dropJunk({ keep = { "minecraft:cobblestone" }, only = true })
    eq(left(), "1,5,6", "only: nur Bruchstein (plus Kohle und Ausruestung)")
  end)
  turtle.getItemDetail, turtle.select, turtle.dropUp = real[1], real[2], real[3]
  assert(ok, err)
end)

test("Steinjagd: sammelt bis zur Menge und meldet, wie viel es war", function()
  local store = require("store")
  store.save("/.nav", { pos = { x = 0, y = 0, z = 0, f = 3 }, home = { x = 0, y = 0, z = 0, f = 0 }, gps = true })
  require("zones").add("test", -100, -100, -100, 100, 100, 100)
  local inv = {}
  local real = { turtle.getItemDetail, turtle.getItemCount, turtle.forward }
  turtle.getItemDetail = function(s) return inv[s] end
  turtle.getItemCount = function(s) return inv[s] and inv[s].count or 0 end
  -- jeder Schritt bringt einen Bruchstein ins Inventar
  turtle.forward = function()
    for s = 1, 16 do
      if not inv[s] then inv[s] = { name = "minecraft:cobblestone", count = 1 } return true end
      if inv[s].count < 64 then inv[s].count = inv[s].count + 1 return true end
    end
    return true
  end
  local ok, res = pcall(function()
    local mine = require("mine")
    return mine.run(mine.stonehunt, { amount = 20, home = false }, function() end)
  end)
  turtle.getItemDetail, turtle.getItemCount, turtle.forward = real[1], real[2], real[3]
  assert(ok, res)
  assert(res:find("^Fertig") and res:find("Gesammelt: %d+ von 20 %(minecraft:cobblestone"), res)
  local got = tonumber(res:match("Gesammelt: (%d+)"))
  assert(got >= 20 and got <= 28, "gesammelt " .. got)
end)

local function orehuntSetup(zoneList)
  local store = require("store")
  store.save("/.nav", { pos = { x = 0, y = 0, z = 0, f = 3 }, home = { x = 0, y = 0, z = 0, f = 3 }, gps = true })
  local zones = require("zones")
  for i, z in ipairs(zoneList) do zones.add("z" .. i, table.unpack(z)) end
  local scans = 0
  local scanner = { scan = function() scans = scans + 1 return {} end }
  turtle.getItemDetail = function(slot)
    if slot == 1 then return { name = "advancedperipherals:geo_scanner", count = 1 } end
  end
  turtle.getEquippedRight = function() return nil end
  local wrap = peripheral.wrap
  peripheral.wrap = function(side) if side == "left" then return scanner end end
  return function()
    peripheral.wrap = wrap
    turtle.getItemDetail = function() return nil end
    return scans
  end
end

test("B5: Bereich zaehlt erst nach dem Scan als erledigt", function()
  local done = orehuntSetup({ { -1, -1, -1, 20, 1, 1 } })
  local mine = require("mine")
  local opts = { rounds = 2, radius = 8, home = false }
  local res = mine.run(mine.orehunt, opts, function() end)
  local scans = done()
  eq(scans, 2, "Scans")
  local n = 0
  for _ in pairs(opts.scanned) do n = n + 1 end
  eq(n, 2, "erledigte Bereiche")
  assert(res:find("^Fertig"), res)
end)

test("B5: unerreichbarer Bereich zaehlt nicht als erledigt", function()
  -- zwei Zonen mit Luecke dazwischen: zum Bereich bei x=16 gibt es keinen erlaubten Weg
  local done = orehuntSetup({ { -1, -1, -1, 5, 1, 1 }, { 14, -1, -1, 20, 1, 1 } })
  local mine = require("mine")
  local opts = { rounds = 2, radius = 8, home = false }
  mine.run(mine.orehunt, opts, function() end)
  local scans = done()
  eq(scans, 1, "nur der erreichbare Bereich wird gescannt")
  local n = 0
  for _ in pairs(opts.scanned) do n = n + 1 end
  eq(n, 1, "erledigt")
  eq(opts.unreachable["16,0,0"], true, "als unerreichbar gemerkt")
end)

-- weitere Testdateien bekommen test/eq als globale Funktionen
_G.test, _G.eq = test, eq
_G.runClaude, _G.toolUse, _G.text, _G.lastMsg = runClaude, toolUse, text, lastMsg
dofile("tests/crypto_tests.lua")
dofile("tests/mq_tests.lua")
dofile("tests/gateway_tests.lua")
dofile("tests/sync_tests.lua")
dofile("tests/sign_tests.lua")
dofile("tests/job_tests.lua")
dofile("tests/command_tests.lua")

say(("\n%d ok, %d fehlgeschlagen"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
