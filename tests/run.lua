-- Tests ausserhalb von Minecraft:  cd turtle-claude && lua5.2 tests/run.lua
package.path = "./?.lua;./tests/?.lua;" .. package.path
local say = function(s) io.write(s, "\n") end -- print ist durch die CC-Attrappe belegt
local cc = require("cc")

local MODULES = { "store", "zones", "gear", "nav", "path", "mine", "colony", "mq", "version", "broker", "sync", "crypto", "services", "jobsvc", "jobrunner" }
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
  dofile("claude.lua")
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
  web({ ["manifests/turtle.txt"] = "# Kommentar\nnav.lua\nupdate.lua\n", ["nav.lua"] = "neu", ["update.lua"] = "-- u" }, SHA)
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
  web({ ["manifests/turtle.txt"] = "nav.lua\nfehlt.lua\n", ["nav.lua"] = "neu" }, SHA)
  dofile("update.lua")
  eq(cc.readFile("/nav.lua"), "alt")
  eq(fs.exists("/.update"), false, "Temp-Verzeichnis aufgeraeumt")
  eq(fs.exists("/.version"), false)
end)

test("B8: schon aktuell -> nichts laden", function()
  web({ ["manifests/turtle.txt"] = "nav.lua\n", ["nav.lua"] = "neu" }, SHA)
  dofile("update.lua")
  cc.gets = {}
  dofile("update.lua")
  eq(#cc.gets, 1, "nur die API-Abfrage")
end)

test("B8: ohne API (Limit) wird vom Branch geladen", function()
  web({ ["manifests/turtle.txt"] = "nav.lua\n", ["nav.lua"] = "neu" }, nil)
  dofile("update.lua")
  eq(cc.readFile("/nav.lua"), "neu")
end)

test("B8: Kanal und Rolle waehlen Branch und Manifest", function()
  settings.values["claude.channel"] = "beta"
  settings.values["claude.role"] = "miner"
  cc.web = { ["api:beta"] = { sha = SHA }, [SHA .. "/manifests/miner.txt"] = "nav.lua\n", [SHA .. "/nav.lua"] = "x" }
  dofile("update.lua")
  eq(cc.readFile("/nav.lua"), "x")
  assert(cc.gets[1]:find("commits/beta$"), cc.gets[1])
end)

test("P0.6: Rollenwechsel raeumt Dateien der alten Rolle weg", function()
  web({ ["manifests/turtle.txt"] = "nav.lua\nclaude.lua\n", ["nav.lua"] = "n", ["claude.lua"] = "c" }, SHA)
  dofile("update.lua")
  eq(cc.readFile("/claude.lua"), "c")
  settings.values["claude.role"] = "miner"
  web({ ["manifests/miner.txt"] = "nav.lua\n", ["nav.lua"] = "n2" }, "fff0000111")
  dofile("update.lua")
  eq(fs.exists("/claude.lua"), false, "claude.lua gehoert nicht zum Miner")
  eq(cc.readFile("/nav.lua"), "n2")
end)

test("P0.6: bootstrap richtet Rolle und Kanal ein und installiert", function()
  turtle = turtle or {}
  cc.web = {
    ["main/update.lua"] = assert(io.open("update.lua")):read("*a"),
    ["api:main"] = { sha = SHA },
    [SHA .. "/manifests/miner.txt"] = "nav.lua\n",
    [SHA .. "/nav.lua"] = "n",
  }
  loadfile("bootstrap.lua")("miner")
  eq(settings.values["claude.role"], "miner")
  eq(settings.values["claude.channel"], "main")
  eq(cc.readFile("/nav.lua"), "n")
end)

test("P0.6: Manifeste passen zum Repository", function()
  local function lines(file)
    local t = {}
    for l in io.lines(file) do if not l:match("^%s*#") and l ~= "" then t[#t + 1] = l end end
    return t
  end
  for _, role in ipairs({ "turtle", "miner", "gps", "gateway", "central" }) do
    for _, name in ipairs(lines("manifests/" .. role .. ".txt")) do
      assert(io.open(name), role .. ": Datei fehlt im Repository: " .. name)
    end
  end
  -- files.txt ist fuer alte update-Versionen und muss dem Turtle-Manifest entsprechen
  eq(table.concat(lines("files.txt"), ","), table.concat(lines("manifests/turtle.txt"), ","), "files.txt")
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

say(("\n%d ok, %d fehlgeschlagen"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
