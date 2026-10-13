-- update: holt alle Programme in der neuesten Version von GitHub
-- Kanal = Git-Branch:  set claude.channel beta   (Standard: main)
-- Erst wird alles nach /.update/ geladen. Nur wenn jede Datei da ist, werden die alten ersetzt,
-- ein abgebrochener Download hinterlaesst also nie eine Mischung aus alter und neuer Version.
local REPO = "https://raw.githubusercontent.com/Hiabst2/turtle-claude/"
local channel = settings.get("claude.channel", "main")
local BASE = REPO .. channel .. "/"
local TMP = "/.update"

local function get(path)
  -- Zeitstempel umgeht den Cache von GitHub, sonst kommt bis zu 5 Minuten die alte Version
  local res, err = http.get(BASE .. path .. "?t=" .. os.epoch("utc"))
  if not res then return nil, err end
  local body = res.readAll()
  res.close()
  return body
end

print("Kanal: " .. channel)
local list, err = get("files.txt")
if not list then printError("Dateiliste nicht ladbar: " .. tostring(err)) return end

local names = {}
for name in list:gmatch("[^\r\n]+") do names[#names + 1] = name end

-- 1. alles herunterladen
if fs.exists(TMP) then fs.delete(TMP) end
fs.makeDir(TMP)
for _, name in ipairs(names) do
  local body, e = get(name)
  if not body then
    printError("FEHLER " .. name .. ": " .. tostring(e))
    fs.delete(TMP)
    print("Update abgebrochen, es wurde nichts geaendert.")
    return
  end
  local h = fs.open(TMP .. "/" .. name, "w")
  h.write(body)
  h.close()
end

-- 2. erst jetzt austauschen
for _, name in ipairs(names) do
  if fs.exists(name) then fs.delete(name) end
  fs.move(TMP .. "/" .. name, name)
  -- alte Kopie ohne .lua (z.B. von pastebin get) entfernen, die wuerde sonst beim Starten Vorrang haben
  local bare = name:gsub("%.lua$", "")
  if bare ~= name and fs.exists(bare) and not fs.isDir(bare) then
    fs.delete(bare)
    print("alte Datei '" .. bare .. "' entfernt")
  end
end
fs.delete(TMP)
print(#names .. " Dateien aktualisiert. Starten mit: claude")
