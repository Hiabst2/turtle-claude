-- update: holt die Programme der eigenen Rolle in der neuesten Version von GitHub
--   set claude.role turtle|miner|gps     (Standard: turtle)
--   set claude.channel <branch>          (Standard: main)
-- Welche Dateien eine Rolle braucht, steht in roles/<rolle>.txt. Im Repository liegen sie in Ordnern
-- (core/, turtle/, net/ ...), auf dem Geraet landen alle flach im Hauptverzeichnis: aus turtle/nav.lua
-- wird /nav.lua. So bleibt require("nav") ueberall gleich.
-- Alle Dateien kommen vom selben Commit. Erst wird alles nach /.update/ geladen, nur wenn jede Datei
-- da ist, werden die alten ersetzt. Dateien, die die Rolle nicht mehr braucht, werden entfernt.
-- Laeuft ohne andere Module, damit es auch auf einem frischen Computer funktioniert.
local OWNER_REPO = "Hiabst2/turtle-claude"
local RAW = "https://raw.githubusercontent.com/" .. OWNER_REPO .. "/"
local API = "https://api.github.com/repos/" .. OWNER_REPO .. "/commits/"
local TMP, VERSION_FILE = "/.update", "/.version"
-- 2 = Dateien kommen aus roles/ und werden flach installiert. Aeltere update-Versionen kannten das nicht
-- (siehe manifests/): ein Stand ohne layout 2 gilt nie als aktuell.
local LAYOUT = 2

local role = settings.get("claude.role", "turtle")
local channel = settings.get("claude.channel", "main")

local function fetch(url)
  local res, err = http.get(url)
  if not res then return nil, err end
  local body = res.readAll()
  res.close()
  return body
end

local function readVersion()
  if not fs.exists(VERSION_FILE) then return nil end
  local f = fs.open(VERSION_FILE, "r")
  local v = textutils.unserialize(f.readAll())
  f.close()
  return v
end

-- Dateiname auf dem Geraet: turtle/nav.lua -> nav.lua
local function base(path) return path:match("[^/]+$") end

-- Commit des Kanals bestimmen. Klappt das nicht (API-Limit), wird direkt vom Branch geladen.
local ref, sha = channel, nil
local apiBody = fetch(API .. channel)
if apiBody then
  local data = textutils.unserializeJSON(apiBody)
  if type(data) == "table" and type(data.sha) == "string" then ref, sha = data.sha, data.sha end
end
local function get(path)
  -- beim Laden vom Branch umgeht der Zeitstempel den Cache von GitHub
  return fetch(RAW .. ref .. "/" .. path .. (sha and "" or ("?t=" .. os.epoch("utc"))))
end

local old = readVersion()
local force = select(1, ...) == "force"
-- Ausgaben passen auf den Turtle-Bildschirm (39 Zeichen breit)
print(("Rolle %s, Kanal %s"):format(role, channel))
if sha then print("Commit " .. sha:sub(1, 7)) end
if not force and old and old.layout == LAYOUT and sha and old.sha == sha and old.role == role then
  print("Schon aktuell.")
  print("Neu laden: update force")
  return
end

local list, err = get("roles/" .. role .. ".txt")
if not list then printError("Dateiliste fuer " .. role .. " fehlt:") printError(tostring(err)) return end
local paths, names, seen = {}, {}, {}
for path in list:gmatch("[^\r\n]+") do
  if not path:match("^%s*#") and path:match("%S") then
    local name = base(path)
    if seen[name] then
      printError("Doppelter Dateiname: " .. name)
      printError(seen[name] .. ", " .. path)
      print("Update abgebrochen.")
      return
    end
    seen[name] = path
    paths[#paths + 1], names[#names + 1] = path, name
  end
end

-- 1. alles herunterladen
if fs.exists(TMP) then fs.delete(TMP) end
fs.makeDir(TMP)
for i, path in ipairs(paths) do
  local body, e = get(path)
  if not body then
    printError("FEHLER " .. path .. ": " .. tostring(e))
    fs.delete(TMP)
    print("Update abgebrochen,")
    print("es wurde nichts geaendert.")
    return
  end
  local h = fs.open(TMP .. "/" .. names[i], "w")
  h.write(body)
  h.close()
end

-- 2. erst jetzt austauschen
local keep = {}
for _, name in ipairs(names) do
  keep[name] = true
  if fs.exists(name) then fs.delete(name) end
  fs.move(TMP .. "/" .. name, name)
  -- alte Kopie ohne .lua (z.B. von pastebin get) entfernen, die wuerde sonst beim Starten Vorrang haben
  local bare = name:gsub("%.lua$", "")
  if bare ~= name and fs.exists(bare) and not fs.isDir(bare) then
    fs.delete(bare)
    print("alte Datei entfernt: " .. bare)
  end
end
fs.delete(TMP)

-- 3. Dateien der alten Version, die nicht mehr gebraucht werden (z.B. nach Rollenwechsel)
if old and old.files then
  for _, name in ipairs(old.files) do
    if not keep[name] and fs.exists(name) and not fs.isDir(name) then
      fs.delete(name)
      print("entfernt: " .. name)
    end
  end
end

local info = { sha = sha, channel = channel, role = role, files = names, layout = LAYOUT, updated = os.epoch("utc") }
local f = fs.open(VERSION_FILE .. ".tmp", "w")
f.write(textutils.serialize(info))
f.close()
if fs.exists(VERSION_FILE) then fs.delete(VERSION_FILE) end
fs.move(VERSION_FILE .. ".tmp", VERSION_FILE)

print(#names .. " Dateien aktualisiert.")
if old and old.sha and sha and old.sha ~= sha then print(old.sha:sub(1, 7) .. " -> " .. sha:sub(1, 7)) end
