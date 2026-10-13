-- bootstrap: richtet ein neues Geraet ein (Rolle waehlen, Einstellungen, Programme laden)
--   wget run https://raw.githubusercontent.com/Hiabst2/turtle-claude/main/bootstrap.lua
-- Ohne Rueckfragen zu Rolle und Kanal:  bootstrap <rolle> [kanal]
local RAW = "https://raw.githubusercontent.com/Hiabst2/turtle-claude/"
local args = { ... }

local ROLES = {
  turtle = { turtle = true, text = "Claude-Turtle: Chat, Mining, Kolonie (braucht API-Key und Chat Box)" },
  miner = { turtle = true, text = "Mining-Turtle ohne Claude (stripmine, orehunt, ... im Terminal)" },
  gps = { turtle = false, text = "GPS-Sender (Computer mit Modem)" },
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

-- Rollenspezifische Einstellungen nur abfragen, wenn interaktiv eingerichtet wird
if not args[1] then
  if role == "turtle" then
    if not settings.get("claude.key") then
      settings.set("claude.key", ask("Claude API-Key (sk-ant-...)", nil, true))
    end
    settings.set("claude.owner", ask("Dein Minecraft-Name (darf die Turtle steuern)", settings.get("claude.owner")))
    os.setComputerLabel(ask("Name der Turtle (Chat-Ansprache)", os.getComputerLabel() or "Hiabst"))
  elseif role == "gps" then
    print("Koordinaten DIESES Computers (F3, Targeted Block):")
    for _, axis in ipairs({ "x", "y", "z" }) do
      settings.set("gps." .. axis, tonumber(ask(axis, settings.get("gps." .. axis))))
    end
    if not os.getComputerLabel() then os.setComputerLabel("gps-" .. os.getComputerID()) end
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
  print("Naechste Schritte: sethome, gpsfix, Zone anlegen (zone), dann z.B. orehunt.")
else
  print("Neustart startet den GPS-Sender: reboot")
end
