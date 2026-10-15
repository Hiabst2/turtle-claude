-- startup: was nach jedem Neustart laeuft (z.B. wenn der Chunk wieder geladen wird), je nach Rolle
--   turtle: claude starten (setzt unterbrochene Auftraege selbst fort)
--   miner:  Worker-Dienst (Auftraege von der Zentrale); ohne TurtleMQ nur unterbrochenen Auftrag fortsetzen
--   central: Zentrale mit Job-, Map- und Path-Dienst
--   command: Leitstelle (Claude mit Chat Box)
--   gps:    GPS-Sender starten
--   gateway: TurtleMQ-Gateway starten
local role = settings.get("claude.role", "turtle")

-- Umstieg auf die Ordner im Repository: aeltere update-Versionen holen nur noch update.lua und startup.lua
-- (siehe manifests/ und files.txt). Fehlt der neue Stand (layout 2), hier einmal das neue update ausfuehren.
local function layout()
  if not fs.exists("/.version") then return nil end
  local f = fs.open("/.version", "r")
  local ok, v = pcall(textutils.unserialize, f.readAll())
  f.close()
  return ok and type(v) == "table" and v.layout or nil
end
if layout() ~= 2 and fs.exists("update.lua") then
  print("Neue Dateistruktur: lade alle Programme neu ...")
  shell.run("update", "force")
end

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
