-- diag: alles, was man zur Fehlersuche braucht (Foto davon an Claude schicken)
--   diag          alles, seitenweise (Taste = weiter)
--   diag gear     nur Ausruestung      diag home   nur Position/Heimplatz      diag log [n]   nur Meldungen
-- Alles steht zusaetzlich in diag.txt (in Ruhe ansehen mit: edit diag.txt)
local nav = require("nav")
local gear = require("gear")
local args = { ... }
local only, n = args[1], tonumber(args[2]) or tonumber(args[1]) or 8
if tonumber(only) then only = nil end

local lines = {}
local function add(text) lines[#lines + 1] = text end
local function readLines(path)
  local out = {}
  if fs.exists(path) then
    local f = fs.open(path, "r")
    for line in (f.readAll() or ""):gmatch("[^\n]+") do out[#out + 1] = line end
    f.close()
  end
  return out
end

if not only then
  local ok, version = pcall(require, "version")
  add("Version: " .. (ok and version.text() or "?"))
  add(("Label %s, ID %d, Rolle %s, MQ %s"):format(tostring(os.getComputerLabel()), os.getComputerID(),
    tostring(settings.get("claude.role")), tostring(settings.get("mq.enabled"))))
end

if not only or only == "home" then
  add("-- Position --")
  add(nav.where())
  add("Heimplatz-Protokoll (neueste unten):")
  local log = readLines(nav.HOMELOG)
  if #log == 0 then add(" (leer)") end
  for i = math.max(1, #log - 4), #log do add(" " .. log[i]) end
end

if not only or only == "gear" then
  add("-- Ausruestung --")
  local okRunner, runner = pcall(require, "jobrunner")
  if okRunner then add(runner.details()[1]) end
  local function eqText(side)
    local name = gear.equipped(side)
    if name == nil then return "unbekannt (" .. tostring(peripheral.getType(side) or "kein Peripheral") .. ")" end
    return name == "" and "leer" or name
  end
  add("Links:  " .. eqText("left"))
  add("Rechts: " .. eqText("right"))
  -- roh, was CC liefert (fuer die Fehlersuche)
  for _, fnName in ipairs({ "getEquippedLeft", "getEquippedRight" }) do
    local fn = turtle[fnName]
    if type(fn) ~= "function" then
      add(" " .. fnName .. ": gibt es nicht (" .. type(fn) .. ")")
    else
      local ok, res = pcall(fn)
      local sok, text = pcall(textutils.serialize, res, { compact = true })
      add(" " .. fnName .. ": " .. (ok and "" or "FEHLER ") .. tostring(sok and text or res):gsub("%s+", " "):sub(1, 60))
    end
  end
  for _, k in ipairs({ "pickaxe", "modem", "geo_scanner", "minecraft:chest" }) do
    add(" " .. k:gsub("^minecraft:", "") .. ": " .. (gear.where(k) or "fehlt"))
  end
end

if not only or only == "log" then
  add("-- Letzte Meldungen --")
  local log = readLines("/.worklog")
  if #log == 0 then add(" (keine)") end
  for i = math.max(1, #log - n + 1), #log do add(" " .. log[i]) end
end

-- alles in eine Datei, dann seitenweise anzeigen
local f = fs.open("diag.txt", "w")
f.write(table.concat(lines, "\n") .. "\n")
f.close()
term.clear()
term.setCursorPos(1, 1)
textutils.pagedPrint(table.concat(lines, "\n"))
print("(alles auch in diag.txt: edit diag.txt)")
