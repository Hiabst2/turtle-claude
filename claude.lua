-- claude.lua - eine Mining Turtle, die per Chat mit Claude redet
-- Setup:  set claude.key sk-ant-...      (API-Key, Pflicht)
--         label set Hiabst               (Name der Turtle = Chat-Trigger)
--         set claude.model claude-opus-5 (optional)
-- Chat:   ohne Chat Box ueber das Turtle-Terminal,
--         mit Advanced Peripherals Chat Box: "Hiabst, grab mir einen Tunnel"
--         "stop" bricht den laufenden Auftrag ab.
-- Braucht nav.lua und mine.lua im selben Ordner.

if not turtle then printError("Laeuft nur auf einer Turtle.") return end
if not http then printError("HTTP ist in der ComputerCraft-Config deaktiviert.") return end

local KEY = settings.get("claude.key")
if not KEY then print("Kein API-Key. Setzen mit:\n  set claude.key sk-ant-...") return end

local nav = require("nav")
local mine = require("mine")

local MODEL = settings.get("claude.model", "claude-opus-5")
local NAME = os.getComputerLabel() or "Hiabst"
local TRIGGER = NAME:lower()
local API = "https://api.anthropic.com/v1/messages"
local MAX_HISTORY = 40
local MAX_STEPS = 25

local chatBox = peripheral.find("chatBox")

-- Einzelbefehle fuer turtle_do. n = Wiederholungen
local REPEAT = {
  forward = function() return nav.forward(false) end,
  back = function() return nav.back(false) end,
  up = function() return nav.up(false) end,
  down = function() return nav.down(false) end,
  turnLeft = nav.turnLeft,
  turnRight = nav.turnRight,
  dig = function() return nav.dig("front") end,
  digUp = function() return nav.dig("up") end,
  digDown = function() return nav.dig("down") end,
  attack = turtle.attack, attackUp = turtle.attackUp, attackDown = turtle.attackDown,
}

local function look(fn)
  return function()
    local ok, data = fn()
    return true, ok and data.name or "Luft"
  end
end

-- n = Slot bzw. Anzahl
local SINGLE = {
  place = turtle.place, placeUp = turtle.placeUp, placeDown = turtle.placeDown,
  drop = turtle.drop, dropUp = turtle.dropUp, dropDown = turtle.dropDown,
  suck = turtle.suck, suckUp = turtle.suckUp, suckDown = turtle.suckDown,
  select = function(n) return turtle.select(n or 1) end,
  inspect = look(turtle.inspect), inspectUp = look(turtle.inspectUp), inspectDown = look(turtle.inspectDown),
}

local CMD_NAMES = {}
for k in pairs(REPEAT) do CMD_NAMES[#CMD_NAMES + 1] = k end
for k in pairs(SINGLE) do CMD_NAMES[#CMD_NAMES + 1] = k end
table.sort(CMD_NAMES) -- feste Reihenfolge, damit der Prompt-Cache greift

local function runCommands(input)
  local log = {}
  local function fail(text)
    log[#log + 1] = text
    log[#log + 1] = nav.where()
    return table.concat(log, "\n")
  end
  for _, c in ipairs(input.commands or {}) do
    local name = c.cmd
    if REPEAT[name] then
      local times = math.max(1, math.min(tonumber(c.n) or 1, 64))
      for i = 1, times do
        local ok, res, err = pcall(REPEAT[name])
        if not ok or not res then
          return fail(("%s: fehlgeschlagen bei %d/%d (%s)"):format(name, i, times, tostring(ok and err or res)))
        end
      end
      log[#log + 1] = ("%s x%d ok"):format(name, times)
    elseif SINGLE[name] then
      local ok, res, info = pcall(SINGLE[name], c.n)
      if not ok or not res then
        return fail(("%s: fehlgeschlagen (%s)"):format(name, tostring(ok and info or res)))
      end
      log[#log + 1] = name .. (info and (": " .. tostring(info)) or " ok")
    else
      return fail(tostring(name) .. ": unbekannter Befehl")
    end
  end
  log[#log + 1] = nav.where()
  return table.concat(log, "\n")
end

local function status()
  local lines = { "Fuel: " .. tostring(turtle.getFuelLevel()) .. " / " .. tostring(turtle.getFuelLimit()), nav.where(),
    "Ausgewaehlter Slot: " .. turtle.getSelectedSlot(), "Inventar:" }
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then lines[#lines + 1] = ("  Slot %d: %s x%d"):format(slot, item.name, item.count) end
  end
  for _, d in ipairs({ { "vorne", turtle.inspect }, { "oben", turtle.inspectUp }, { "unten", turtle.inspectDown } }) do
    local ok, data = d[2]()
    lines[#lines + 1] = d[1] .. ": " .. (ok and data.name or "Luft")
  end
  return table.concat(lines, "\n")
end

local SYSTEM = ([[Du bist %s, eine Mining Turtle in Minecraft (ComputerCraft). Spieler reden per Chat mit dir.
- Antworte kurz (1-3 Saetze), locker, auf Deutsch und OHNE Umlaute (ae, oe, ue, ss), das Terminal kann keine.
- Nimm fuer groessere Aufgaben die Programme stripmine, tunnel, go_home und go_to. Die laufen komplett auf der
  Turtle, kuemmern sich selbst um Fuel, Erzadern, volles Inventar und den Heimweg und kosten nur einen Aufruf.
  turtle_do ist fuer kleine Handgriffe gedacht.
- Der Heimplatz ist dort, wo die Turtle gestartet ist oder set_home aufgerufen wurde. Direkt dahinter steht die Truhe.
- Positionen sind relativ zum Start, bis gps_locate erfolgreich war. Danach sind es echte Weltkoordinaten.
- Vorsicht mit Lava und Abgruenden: erst inspizieren, dann graben.
- Baue nichts ab, was offensichtlich Spielern gehoert (Truhen, Maschinen, Haeuser), ausser man bittet dich darum.
- Spieler koennen jederzeit "stop" schreiben, dann bricht das laufende Programm ab.]]):format(NAME)

-- jedes Schema braucht eine eigene Tabelle, serializeJSON mag keine doppelt verwendeten
local function empty() return { type = "object", properties = {} } end

local function int(desc) return { type = "integer", description = desc } end

local TOOLS = {
  {
    name = "turtle_do",
    description = "Fuehrt Turtle-Befehle der Reihe nach aus und bricht beim ersten Fehlschlag ab. "
      .. "Bewegen, Drehen, Graben, Angreifen: n = Wiederholungen (max 64). Bewegen graebt NICHT automatisch. "
      .. "select: n = Slot 1-16. drop/suck: n = Anzahl Items (optional). inspect*: liefert den Blocknamen.",
    input_schema = {
      type = "object",
      properties = {
        commands = {
          type = "array",
          items = {
            type = "object",
            properties = { cmd = { type = "string", enum = CMD_NAMES }, n = { type = "integer" } },
            required = { "cmd" },
          },
        },
      },
      required = { "commands" },
    },
  },
  {
    name = "status",
    description = "Fuel, Position, Heimplatz, Inventar und die Bloecke vorne/oben/unten.",
    input_schema = empty(),
  },
  {
    name = "stripmine",
    description = "Stripmine ab der aktuellen Position in Blickrichtung: 2 hoher Hauptgang, alle `spacing` Bloecke "
      .. "ein Seitengang links und rechts. Baut Erzadern in Boden, Decke und Waenden komplett ab, wirft Bruchstein "
      .. "und Co weg, faehrt bei vollem Inventar zur Truhe und macht weiter. Am Ende geht es heim zum Ausladen.",
    input_schema = {
      type = "object",
      properties = {
        length = int("Laenge des Hauptgangs (Standard 32, max 256)"),
        branch = int("Laenge jedes Seitengangs (Standard 8, 0 = keine Seitengaenge)"),
        spacing = int("Abstand der Seitengaenge (Standard 3)"),
        home = { type = "boolean", description = "Am Ende heimfahren und ausladen (Standard true)" },
        drop_junk = { type = "boolean", description = "Bruchstein, Erde, Kies usw. wegwerfen (Standard true)" },
      },
    },
  },
  {
    name = "tunnel",
    description = "Graebt einen Tunnel. Die Turtle ist die untere linke Ecke, der Tunnel geht nach vorne, "
      .. "rechts und oben. Am Ende steht sie am Tunnelende, ausser home = true.",
    input_schema = {
      type = "object",
      properties = {
        length = int("Laenge (Standard 16)"),
        width = int("Breite (Standard 3)"),
        height = int("Hoehe (Standard 3)"),
        home = { type = "boolean", description = "Am Ende heimfahren und ausladen (Standard false)" },
        drop_junk = { type = "boolean", description = "Bruchstein, Erde, Kies usw. wegwerfen (Standard true)" },
      },
    },
  },
  {
    name = "go_home",
    description = "Faehrt zum Heimplatz (graebt sich notfalls durch) und laedt optional in die Truhe dahinter aus.",
    input_schema = { type = "object", properties = { unload = { type = "boolean", description = "Standard true" } } },
  },
  {
    name = "go_to",
    description = "Faehrt zu einer Koordinate im aktuellen Koordinatensystem und graebt sich notfalls durch.",
    input_schema = {
      type = "object",
      properties = { x = { type = "integer" }, y = { type = "integer" }, z = { type = "integer" } },
      required = { "x", "y", "z" },
    },
  },
  { name = "set_home", description = "Macht die aktuelle Position zum Heimplatz.", input_schema = empty() },
  { name = "refuel", description = "Verbrennt Kohle und andere Brennstoffe aus dem Inventar.", input_schema = empty() },
  {
    name = "gps_locate",
    description = "Bestimmt Position und Blickrichtung per GPS und stellt auf Weltkoordinaten um. "
      .. "Braucht ein Wireless/Ender Modem im Inventar und ein GPS-Netz in Reichweite.",
    input_schema = empty(),
  },
}

local history = {}

local function trimHistory()
  while #history > MAX_HISTORY do
    table.remove(history, 1)
    -- nur an einer echten Spielernachricht beginnen, nie mitten in einem Tool-Aufruf
    while history[1] and not (history[1].role == "user" and type(history[1].content) == "string") do
      table.remove(history, 1)
    end
  end
end

local function callClaude()
  local body = textutils.serializeJSON({
    model = MODEL,
    max_tokens = 4096,
    system = SYSTEM,
    tools = TOOLS,
    cache_control = { type = "ephemeral" }, -- gleichbleibender Teil kostet beim naechsten Mal ~1/10
    output_config = { effort = "low" }, -- schnelle Antworten, die Turtle soll nicht ewig gruebeln
    messages = history,
  }, { unicode_strings = true })

  local res, err, errRes = http.post({
    url = API,
    body = body,
    headers = {
      ["content-type"] = "application/json",
      ["x-api-key"] = KEY,
      ["anthropic-version"] = "2023-06-01",
    },
    timeout = 60, -- CC erlaubt maximal 60 Sekunden
  })
  if not res then
    local detail = ""
    if errRes then detail = errRes.readAll() or ""; errRes.close() end
    return nil, tostring(err) .. " " .. detail
  end
  local text = res.readAll()
  res.close()
  return textutils.unserializeJSON(text)
end

local function reply(text, toChat)
  term.setTextColor(colors.lime)
  print(NAME .. ": " .. text)
  term.setTextColor(colors.white)
  if not (toChat and chatBox) then return end
  for i = 1, #text, 240 do
    local chunk = text:sub(i, i + 239)
    for _ = 1, 5 do -- die Chat Box hat einen Cooldown
      if chatBox.sendMessage(chunk, NAME) then break end
      sleep(1)
    end
  end
end

local function runTool(name, input, say)
  term.setTextColor(colors.gray)
  print("[" .. name .. "]")
  term.setTextColor(colors.white)

  if name == "turtle_do" then return runCommands(input) end
  if name == "status" then return status() end
  if name == "stripmine" then return mine.run(mine.stripmine, input, say) end
  if name == "tunnel" then return mine.run(mine.tunnel, input, say) end
  if name == "go_home" then
    local ok, err = pcall(nav.goHome)
    if not ok or not err then return "Heimweg fehlgeschlagen: " .. tostring(err) .. "\n" .. nav.where() end
    if input.unload == false then return "Daheim. " .. nav.where() end
    local unloaded, info = nav.unload()
    return (unloaded and ("Daheim, ausgeladen: " .. info .. " Items") or ("Daheim, " .. info)) .. "\n" .. nav.where()
  end
  if name == "go_to" then
    local ok, res, err = pcall(nav.goTo, input.x, input.y, input.z)
    if ok and res then return "Angekommen. " .. nav.where() end
    return "Nicht angekommen: " .. tostring(ok and err or res) .. "\n" .. nav.where()
  end
  if name == "set_home" then nav.setHome(); return "Heimplatz gesetzt. " .. nav.where() end
  if name == "refuel" then return "Fuel: " .. tostring(nav.refuel()) end
  if name == "gps_locate" then
    local ok, res, err = pcall(nav.calibrate)
    if ok and res then return "GPS ok. " .. nav.where() end
    return "GPS fehlgeschlagen: " .. tostring(ok and err or res)
  end
  return "unbekanntes Tool: " .. tostring(name)
end

local function handle(user, text, fromChat)
  nav.resetAbort()
  trimHistory()
  history[#history + 1] = { role = "user", content = user and ("[" .. user .. "] " .. text) or text }
  local say = function(msg) reply(msg, fromChat) end

  for _ = 1, MAX_STEPS do
    local resp, err = callClaude()
    if not resp or resp.type == "error" then
      reply("API-Fehler: " .. tostring(err or (resp.error and resp.error.message)), fromChat)
      return
    end
    -- komplette Antwort zurueckgeben (inkl. Thinking-Bloecke), nicht nur den Text
    history[#history + 1] = { role = "assistant", content = resp.content }

    local said, results = {}, {}
    for _, block in ipairs(resp.content or {}) do
      if block.type == "text" and block.text ~= "" then
        said[#said + 1] = block.text
      end
    end
    if #said > 0 then say(table.concat(said, " ")) end
    for _, block in ipairs(resp.content or {}) do
      if block.type == "tool_use" then
        results[#results + 1] = { type = "tool_result", tool_use_id = block.id, content = runTool(block.name, block.input or {}, say) }
      end
    end
    if resp.stop_reason ~= "tool_use" then return end
    history[#history + 1] = { role = "user", content = results }
  end
  reply("Ich hoer hier mal auf, das waren zu viele Schritte.", fromChat)
end

-- Eingaben aus Terminal und Chat landen in einer Queue, ein Worker arbeitet sie
-- nacheinander ab, damit sich nie zwei Auftraege die Turtle teilen.
local queue = {}
local function enqueue(user, text, fromChat)
  local low = text:lower()
  if low == "stop" or low == "stopp" or low == "halt" then
    nav.abort()
    queue = {}
    reply("Ok, ich stoppe.", fromChat)
    return
  end
  queue[#queue + 1] = { user, text, fromChat }
  os.queueEvent("claude_msg")
end

local function worker()
  while true do
    while #queue > 0 do
      local m = table.remove(queue, 1)
      local ok, e = pcall(handle, m[1], m[2], m[3])
      if not ok then printError(e) end
    end
    os.pullEvent("claude_msg")
  end
end

local function terminalLoop()
  while true do
    local line = read()
    if line and line ~= "" then enqueue(nil, line, false) end
  end
end

local function chatLoop()
  while true do
    local _, user, msg = os.pullEvent("chat")
    if msg:lower():sub(1, #TRIGGER) == TRIGGER then
      local text = msg:sub(#TRIGGER + 1):gsub("^[%s,:!]+", "")
      if text ~= "" then enqueue(user, text, true) end
    end
  end
end

term.clear()
term.setCursorPos(1, 1)
print(NAME .. " ist online (" .. MODEL .. ")")
print(nav.where())
print(chatBox and ("Chat Box gefunden. Im Chat mit \"" .. NAME .. ", ...\" ansprechen.")
  or "Keine Chat Box. Hier tippen. Abbrechen mit Strg+T.")

if chatBox then
  parallel.waitForAny(worker, terminalLoop, chatLoop)
else
  parallel.waitForAny(worker, terminalLoop)
end
