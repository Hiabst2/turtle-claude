-- bootstrap: richtet ein neues Geraet ein (Rolle waehlen, Einstellungen, Programme laden)
--   wget run https://raw.githubusercontent.com/Hiabst2/turtle-claude/main/bootstrap.lua
-- Ohne Rueckfragen zu Rolle und Kanal:  bootstrap <rolle> [kanal]
local RAW = "https://raw.githubusercontent.com/Hiabst2/turtle-claude/"
local args = { ... }

local ROLES = {
  turtle = { turtle = true, text = "Claude-Turtle: Chat, Mining, Kolonie (braucht API-Key und Chat Box)" },
  miner = { turtle = true, text = "Mining-Turtle ohne Claude (stripmine, orehunt, ... im Terminal)" },
  gps = { turtle = false, text = "GPS-Sender (Computer mit Modem)" },
  gateway = { turtle = false, text = "TurtleMQ-Gateway (Computer mit Ender Modem, Chunk dauerhaft laden!)" },
  central = { turtle = false, text = "Zentrale mit Job-Dienst (Computer mit Ender Modem, Chunk dauerhaft laden!)" },
  command = { turtle = false, text = "Leitstelle: Claude mit Chat Box (Computer mit Chat Box + Ender Modem)" },
}

local function ask(question, default, hidden)
  write(question .. (default and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local answer = read(hidden and "*" or nil)
  if answer == "" then return default end
  return answer
end

print("turtle-claude einrichten")
local role = args[1]
if not role then
  for name, r in pairs(ROLES) do
    if (r.turtle and turtle) or (not r.turtle and not turtle) then print("  " .. name .. ": " .. r.text) end
  end
  role = ask("Rolle", turtle and "turtle" or "gps")
end
local r = ROLES[role]
if not r then printError("Unbekannte Rolle: " .. tostring(role)) return end
if r.turtle and not turtle then printError("Die Rolle " .. role .. " geht nur auf einer Turtle.") return end

local channel = args[2] or (args[1] and "main") or ask("Kanal (Git-Branch)", settings.get("claude.channel", "main"))
settings.set("claude.role", role)
settings.set("claude.channel", channel)
if role == "miner" then settings.set("mq.enabled", true) end -- der Worker-Dienst braucht TurtleMQ

-- Rollenspezifische Einstellungen nur abfragen, wenn interaktiv eingerichtet wird
if not args[1] then
  if role == "turtle" or role == "command" then
    if not settings.get("claude.key") then
      settings.set("claude.key", ask("Claude API-Key (sk-ant-...)", nil, true))
    end
    settings.set("claude.owner", ask("Dein Minecraft-Name (darf steuern)", settings.get("claude.owner")))
    os.setComputerLabel(ask("Name im Chat (Ansprache)", os.getComputerLabel()
      or (role == "command" and "Leitstelle" or "Hiabst")))
  elseif role == "gps" then
    print("Koordinaten DIESES Computers (F3, Targeted Block):")
    for _, axis in ipairs({ "x", "y", "z" }) do
      settings.set("gps." .. axis, tonumber(ask(axis, settings.get("gps." .. axis))))
    end
    if not os.getComputerLabel() then os.setComputerLabel("gps-" .. os.getComputerID()) end
  elseif role == "gateway" then
    if not os.getComputerLabel() then os.setComputerLabel("gateway") end
  elseif role == "central" then
    if not os.getComputerLabel() then os.setComputerLabel("Zentrale") end
  elseif role == "miner" then
    os.setComputerLabel(ask("Name der Turtle", os.getComputerLabel() or ("Miner" .. os.getComputerID())))
  end
  -- TurtleMQ-Geheimnis fuer die Signatur, auf allen Geraeten gleich
  if role ~= "gps" then
    local secret = ask("TurtleMQ-Geheimnis (auf allen Geraeten gleich, leer = ohne Signatur)",
      settings.get("mq.secret") and "unveraendert" or nil, true)
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

print("Fertig. Rolle " .. role .. ", Kanal " .. channel .. ".")
if role == "turtle" then
  print("Naechste Schritte: Turtle an den Heimplatz stellen, sethome, gpsfix, dann reboot.")
elseif role == "miner" then
  print("Naechste Schritte: Ender Modem + Geo Scanner ins Inventar, sethome, gpsfix, Zone anlegen,")
  print("dann reboot: der Worker-Dienst holt sich Auftraege von der Zentrale.")
elseif role == "central" then
  print("Neustart startet die Zentrale: reboot. Den Chunk per FTB Chunks dauerhaft laden!")
elseif role == "command" then
  print("Neustart startet die Leitstelle: reboot. Chat Box und Ender Modem anschliessen.")
elseif role == "gateway" then
  print("Neustart startet das Gateway: reboot. Den Chunk per FTB Chunks dauerhaft laden!")
else
  print("Neustart startet den GPS-Sender: reboot")
end
