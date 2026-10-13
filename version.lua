-- version.lua - welche Version laeuft hier? Wird von update in /.version geschrieben.
-- Als Programm: zeigt die Version an. Als Modul (require("version")): M.info(), M.text()

local M = {}

function M.info()
  if not fs.exists("/.version") then return nil end
  local f = fs.open("/.version", "r")
  local ok, v = pcall(textutils.unserialize, f.readAll())
  f.close()
  if ok and type(v) == "table" then return v end
  return nil
end

-- kurz, z.B. "a1b2c3d (main, turtle)"
function M.text()
  local v = M.info()
  if not v then return "unbekannt (noch nie per update installiert)" end
  return ("%s (%s, %s)"):format(v.sha and v.sha:sub(1, 7) or "Branch-Stand", tostring(v.channel), tostring(v.role))
end

-- require("version") uebergibt den Modulnamen, das Programm "version" bekommt keine Argumente
if select(1, ...) ~= "version" then
  print("Version: " .. M.text())
  return
end

return M
