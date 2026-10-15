-- bootstrap: richtet ein neues Geraet ein (Rolle waehlen, Einstellungen, Programme laden)
--   wget run https://raw.githubusercontent.com/Hiabst2/turtle-claude/main/bootstrap.lua
-- Ohne Rueckfragen zu Rolle und Kanal:  bootstrap <rolle> [kanal]
-- Alle Ausgaben passen auf den Turtle-Bildschirm (39 Zeichen breit, prueft ein Test).
local RAW = "https://raw.githubusercontent.com/Hiabst2/turtle-claude/"
local args = { ... }

-- Reihenfolge fest, Beschreibung kurz; was die Rolle braucht, steht in needs (nach der Auswahl angezeigt)
local ROLES = {
  { name = "miner", turtle = true, text = "Mining-Turtle (Auftraege)",
    needs = { "Ender Modem, Spitzhacke" } },
  { name = "turtle", turtle = true, text = "Claude-Turtle (Altlast)",
    needs = { "Chat Box, API-Key" } },
  { name = "gateway", text = "TurtleMQ-Gateway",
    needs = { "Ender Modem", "Chunk dauerhaft laden (FTB Chunks)" } },
  { name = "central", text = "Zentrale: Jobs, Karte",
    needs = { "Ender Modem", "Chunk dauerhaft laden (FTB Chunks)" } },
  { name = "command", text = "Leitstelle: Claude im Chat",
    needs = { "Chat Box, Ender Modem, API-Key" } },
  { name = "gps", text = "GPS-Sender",
    needs = { "Modem" } },
}
local byName = {}
for _, r in ipairs(ROLES) do byName[r.name] = r end

-- Frage in eigener Zeile, Eingabe darunter. Leere Eingabe = Vorgabe (oder nil, wenn es keine gibt).
local function ask(question, default, hidden)
  print(question)
  if default then print("  Enter = " .. tostring(default)) end
  write("> ")
  local answer = read(hidden and "*" or nil)
  if answer == "" then return default end
  return answer
end

-- settings.set mag kein nil: nur setzen, wenn es einen Wert gibt
local function set(key, value)
  if value ~= nil then settings.set(key, value) end
end

print("turtle-claude einrichten")
local role = args[1]
if not role then
  print("Rollen:")
  for _, r in ipairs(ROLES) do
    if (r.turtle and turtle) or (not r.turtle and not turtle) then
      print(("  %-8s %s"):format(r.name, r.text))
    end
  end
  role = ask("Rolle?", turtle and "miner" or "gps")
end
local r = byName[role]
if not r then printError("Unbekannte Rolle: " .. tostring(role)) return end
if r.turtle and not turtle then printError("Rolle " .. role .. " nur auf einer Turtle.") return end
print("Braucht:")
for _, line in ipairs(r.needs) do print("  " .. line) end

local channel = args[2] or (args[1] and "main") or ask("Kanal (Git-Branch)?", settings.get("claude.channel", "main"))
settings.set("claude.role", role)
settings.set("claude.channel", channel)
if role == "miner" then settings.set("mq.enabled", true) end -- der Worker-Dienst braucht TurtleMQ

-- Rollenspezifische Einstellungen nur abfragen, wenn interaktiv eingerichtet wird
if not args[1] then
  if role == "turtle" or role == "command" then
    if not settings.get("claude.key") then
      set("claude.key", ask("Claude API-Key (sk-ant-...)?", nil, true))
      if not settings.get("claude.key") then print("Ohne Key: spaeter set claude.key ...") end
    end
    set("claude.owner", ask("Dein Minecraft-Name (darf steuern)?", settings.get("claude.owner")))
    os.setComputerLabel(ask("Name im Chat?", os.getComputerLabel()
      or (role == "command" and "Leitstelle" or "Hiabst")))
  elseif role == "gps" then
    print("Koordinaten DIESES Computers")
    print("(F3, Targeted Block):")
    for _, axis in ipairs({ "x", "y", "z" }) do
      local v
      repeat
        v = tonumber(ask(axis .. "?", settings.get("gps." .. axis)))
        if not v then print("Bitte eine Zahl.") end
      until v
      settings.set("gps." .. axis, v)
    end
    if not os.getComputerLabel() then os.setComputerLabel("gps-" .. os.getComputerID()) end
  elseif role == "gateway" then
    if not os.getComputerLabel() then os.setComputerLabel("gateway") end
  elseif role == "central" then
    if not os.getComputerLabel() then os.setComputerLabel("Zentrale") end
  elseif role == "miner" then
    os.setComputerLabel(ask("Name der Turtle?", os.getComputerLabel() or ("Miner" .. os.getComputerID())))
  end
  -- TurtleMQ-Geheimnis fuer die Signatur, auf allen Geraeten gleich
  if role ~= "gps" then
    print("TurtleMQ-Geheimnis: auf allen")
    print("Geraeten gleich, leer = keine Signatur")
    local secret = ask("Geheimnis?", settings.get("mq.secret") and "unveraendert" or nil, true)
    if secret and secret ~= "unveraendert" then settings.set("mq.secret", secret) end
  end
end
settings.save()

-- update holen und ausfuehren, das laedt den Rest
local res, err = http.get(RAW .. channel .. "/update.lua?t=" .. os.epoch("utc"))
if not res then printError("update.lua nicht ladbar: " .. tostring(err)) return end
local f = fs.open("update.lua", "w")
f.write(res.readAll())
f.close()
res.close()
shell.run("update")

print("")
print(("Fertig: %s, Kanal %s"):format(role, channel))
print("Naechste Schritte:")
local NEXT = {
  turtle = { "1 Turtle an den Heimplatz stellen", "2 sethome, dann gpsfix", "3 reboot" },
  miner = { "1 An der Zentrale Heimplatz setzen:", "  place home <Name> x y z richtung",
    "2 Toolbox unter den Heimplatz:", "  Ender Modem, Geo Scanner, Kisten",
    "3 reboot: misst sich per GPS ein und", "  holt Auftraege von der Zentrale" },
  central = { "1 Chunk dauerhaft laden", "2 reboot startet die Zentrale" },
  gateway = { "1 Chunk dauerhaft laden", "2 reboot startet das Gateway" },
  command = { "1 Chat Box + Ender Modem anschliessen", "2 reboot startet die Leitstelle" },
  gps = { "reboot startet den GPS-Sender" },
}
for _, line in ipairs(NEXT[role]) do print(line) end
