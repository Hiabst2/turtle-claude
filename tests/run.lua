-- Tests ausserhalb von Minecraft:  cd turtle-claude && lua5.2 tests/run.lua
package.path = "./?.lua;./tests/?.lua;" .. package.path
local say = function(s) io.write(s, "\n") end -- print ist durch die CC-Attrappe belegt
local cc = require("cc")

local MODULES = { "store", "zones", "gear", "nav", "path", "mine", "colony" }
local function fresh()
  cc.reset()
  for _, m in ipairs(MODULES) do package.loaded[m] = nil end
  cc.sent, cc.responses, cc.chat, cc.out, cc.events = {}, {}, {}, {}, {}
  settings.values = {}
end

local passed, failed = 0, 0
local function test(name, fn)
  fresh()
  local ok, err = pcall(fn)
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

say(("\n%d ok, %d fehlgeschlagen"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
