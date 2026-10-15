-- store.lua - Zustandsdateien sicher speichern und laden
-- Speichern: erst nach <datei>.tmp schreiben, die alte Datei wird <datei>.bak, dann .tmp umbenennen.
-- Bricht das Schreiben ab (Chunk entladen, Server-Absturz), bleibt immer eine lesbare Version uebrig.

local M = {}

function M.save(path, tbl)
  local tmp, bak = path .. ".tmp", path .. ".bak"
  local f = fs.open(tmp, "w")
  f.write(textutils.serialize(tbl))
  f.close()
  if fs.exists(path) then
    if fs.exists(bak) then fs.delete(bak) end
    fs.move(path, bak)
  end
  fs.move(tmp, path)
end

local function read(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local text = f.readAll()
  f.close()
  local ok, tbl = pcall(textutils.unserialize, text or "")
  if ok and type(tbl) == "table" then return tbl end
  return nil
end

-- Gibt die Tabelle zurueck, oder nil plus Grund:
--   "missing" = es gab nie eine Datei (normaler Erststart)
--   "corrupt" = Datei und Sicherung sind kaputt (nicht still neu anfangen, sondern melden!)
-- Als drittes Ergebnis kommt true, wenn auf die Sicherung zurueckgegriffen wurde.
function M.load(path)
  local tbl = read(path)
  if tbl then return tbl end
  local backup = read(path .. ".bak")
  if backup then return backup, nil, true end
  -- ein .tmp ohne Hauptdatei: Absturz genau zwischen den beiden Umbenennungen
  local tmp = read(path .. ".tmp")
  if tmp then return tmp, nil, true end
  if fs.exists(path) or fs.exists(path .. ".bak") then return nil, "corrupt" end
  return nil, "missing"
end

return M
