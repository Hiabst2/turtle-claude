-- diag: alles, was man zur Fehlersuche braucht, auf einen Blick (Foto davon an Claude schicken)
local nav = require("nav")
local ok, version = pcall(require, "version")
print("Version: " .. (ok and version.text() or "?"))
print(("Label %s, ID %d, Rolle %s, MQ %s"):format(tostring(os.getComputerLabel()), os.getComputerID(),
  tostring(settings.get("claude.role")), tostring(settings.get("mq.enabled"))))
print(nav.where())
local gear = require("gear")
local function eqText(side)
  local n = gear.equipped(side)
  if n == nil then return "unbekannt (" .. tostring(peripheral.getType(side) or "kein Peripheral") .. ")" end
  return n == "" and "leer" or n
end
print(("Ausgeruestet: links %s, rechts %s"):format(eqText("left"), eqText("right")))
local parts = {}
for _, k in ipairs({ "pickaxe", "modem", "geo_scanner", "minecraft:chest" }) do
  parts[#parts + 1] = k:gsub("^minecraft:", "") .. ": " .. (gear.where(k) or "fehlt")
end
print("Dabei: " .. table.concat(parts, ", "))
print("Heimplatz-Protokoll (neueste unten):")
if fs.exists(nav.HOMELOG) then
  local f = fs.open(nav.HOMELOG, "r")
  local lines = {}
  for line in (f.readAll() or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
  f.close()
  for i = math.max(1, #lines - 5), #lines do print(" " .. lines[i]) end
else
  print(" (leer - Heimplatz wurde seit diesem Update nicht gesetzt)")
end
-- letzte Meldungen des Workers (Scans, Erze, Ende des Auftrags); diag 20 zeigt mehr
local n = tonumber(({ ... })[1]) or 8
if fs.exists("/.worklog") then
  print("Letzte Meldungen:")
  local f = fs.open("/.worklog", "r")
  local lines = {}
  for line in (f.readAll() or ""):gmatch("[^\n]+") do lines[#lines + 1] = line end
  f.close()
  for i = math.max(1, #lines - n + 1), #lines do print(" " .. lines[i]) end
end
