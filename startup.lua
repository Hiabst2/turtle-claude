-- startup: was nach jedem Neustart laeuft (z.B. wenn der Chunk wieder geladen wird), je nach Rolle
--   turtle: claude starten (setzt unterbrochene Auftraege selbst fort)
--   miner:  Worker-Dienst (Auftraege von der Zentrale); ohne TurtleMQ nur unterbrochenen Auftrag fortsetzen
--   central: Zentrale mit Job-, Map- und Path-Dienst
--   command: Leitstelle (Claude mit Chat Box)
--   gps:    GPS-Sender starten
--   gateway: TurtleMQ-Gateway starten
local role = settings.get("claude.role", "turtle")

if role == "gps" then
  shell.run("gpshost")
elseif role == "gateway" then
  shell.run("gateway")
elseif role == "central" then
  shell.run("central")
elseif role == "command" then
  if settings.get("claude.key") then shell.run("command") end
elseif role == "turtle" then
  if settings.get("claude.key") and fs.exists("claude.lua") then shell.run("claude") end
elseif role == "miner" and settings.get("mq.enabled", false) then
  shell.run("worker")
elseif role == "miner" then
  local mine = require("mine")
  if mine.pendingJob() then
    print("Setze unterbrochenen Auftrag fort ...")
    print(mine.resume(print))
  end
end
