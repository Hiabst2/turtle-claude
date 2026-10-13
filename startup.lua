-- startup: was nach jedem Neustart laeuft (z.B. wenn der Chunk wieder geladen wird), je nach Rolle
--   turtle: claude starten (setzt unterbrochene Auftraege selbst fort)
--   miner:  unterbrochenen Auftrag fortsetzen
--   gps:    GPS-Sender starten
local role = settings.get("claude.role", "turtle")

if role == "gps" then
  shell.run("gpshost")
elseif role == "turtle" then
  if settings.get("claude.key") and fs.exists("claude.lua") then shell.run("claude") end
elseif role == "miner" then
  local mine = require("mine")
  if mine.pendingJob() then
    print("Setze unterbrochenen Auftrag fort ...")
    print(mine.resume(print))
  end
end
