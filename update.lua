-- update: holt alle Programme in der neuesten Version von GitHub
local BASE = "https://raw.githubusercontent.com/Hiabst2/turtle-claude/main/"

local function get(path)
  -- Zeitstempel umgeht den Cache von GitHub, sonst kommt bis zu 5 Minuten die alte Version
  local res, err = http.get(BASE .. path .. "?t=" .. os.epoch("utc"))
  if not res then return nil, err end
  local body = res.readAll()
  res.close()
  return body
end

local list, err = get("files.txt")
if not list then printError("Dateiliste nicht ladbar: " .. tostring(err)) return end

local ok = 0
for name in list:gmatch("[^\r\n]+") do
  local body, e = get(name)
  if body then
    local h = fs.open(name, "w")
    h.write(body)
    h.close()
    print("ok   " .. name)
    ok = ok + 1
    -- alte Kopie ohne .lua (z.B. von pastebin get) entfernen, die wuerde sonst beim Starten Vorrang haben
    local bare = name:gsub("%.lua$", "")
    if bare ~= name and fs.exists(bare) and not fs.isDir(bare) then
      fs.delete(bare)
      print("     alte Datei '" .. bare .. "' entfernt")
    end
  else
    printError("FEHLER " .. name .. ": " .. tostring(e))
  end
end
print(ok .. " Dateien aktualisiert. Starten mit: claude")
