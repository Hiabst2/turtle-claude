-- zones.lua - wo die Turtle graben darf
-- Regeln (geprueft bei JEDEM Abbau in nav.dig, egal ob von Claude, Stripmine oder Heimweg):
--   1. Nur mit GPS (Zonen sind Weltkoordinaten aus F3)
--   2. Nie ueber dem Hoehenlimit (Standard Y 50)
--   3. Nur innerhalb einer Mining-Zone. Ohne Zone wird gar nicht gegraben.
--   4. Geschuetzte Bloecke (Truhen, Kolonie, Computer, Tueren ...) nie, auch nicht in einer Zone.
-- Gespeichert in /.zones

local store = require("store")

local M = {}

local FILE = "/.zones"
local data

local function save()
  store.save(FILE, data)
end

local loadErr
data, loadErr = store.load(FILE)
if not data then
  -- Auch bei kaputter Datei sicher: ohne Zonen wird gar nicht gegraben
  data = { maxY = 50, zones = {} }
  if loadErr == "corrupt" then printError("Zonendatei kaputt! Alle Zonen sind weg, bitte neu anlegen (zone add).") end
  save()
end

-- Teile von Blocknamen, die nie abgebaut werden (Erze sind immer erlaubt)
local PROTECTED = {
  "chest", "barrel", "shulker", "minecolonies", "structurize", "computercraft", "advancedperipherals",
  "door", "_bed", "sign", "glass", "create:", "furnace", "crafting_table", "hopper", "anvil", "beacon",
  "storage", "ae2:", -- Tom's/Functional/Sophisticated Storage, Storage Racks, Applied Energistics
}

local function isProtected(name)
  if name:find("_ore$") or name:find("ancient_debris") then return false end
  for _, p in ipairs(PROTECTED) do
    if name:find(p, 1, true) then return true end
  end
  return false
end

M.isProtected = isProtected

local function inside(z, p)
  return p.x >= z.x1 and p.x <= z.x2 and p.y >= z.y1 and p.y <= z.y2 and p.z >= z.z1 and p.z <= z.z2
end

-- pos = Zielblock, name = Blockname (oder nil), gps = ob die Turtle Weltkoordinaten hat
function M.check(pos, name, gps)
  if name and isProtected(name) then return false, "geschuetzter Block (" .. name .. ")" end
  if not gps then return false, "ohne GPS grabe ich nicht, erst gpsfix" end
  if pos.y > data.maxY then return false, ("ueber dem Hoehenlimit Y %d"):format(data.maxY) end
  for _, z in ipairs(data.zones) do
    if inside(z, pos) then return true end
  end
  if #data.zones == 0 then return false, "keine Mining-Zone festgelegt" end
  return false, ("x=%d y=%d z=%d liegt in keiner Mining-Zone"):format(pos.x, pos.y, pos.z)
end

function M.add(name, x1, y1, z1, x2, y2, z2)
  local v = { tonumber(x1), tonumber(y1), tonumber(z1), tonumber(x2), tonumber(y2), tonumber(z2) }
  for i = 1, 6 do
    if not v[i] then return false, "Es braucht 6 Zahlen: x1 y1 z1 x2 y2 z2" end
  end
  if not name or name == "" then return false, "Die Zone braucht einen Namen" end
  local zone = {
    name = name,
    x1 = math.min(v[1], v[4]), x2 = math.max(v[1], v[4]),
    y1 = math.min(v[2], v[5]), y2 = math.max(v[2], v[5]),
    z1 = math.min(v[3], v[6]), z2 = math.max(v[3], v[6]),
  }
  M.delete(name)
  table.insert(data.zones, zone)
  save()
  return true, "Zone gespeichert: " .. M.format(zone)
end

-- Quader um eine Position: radius waagrecht, down nach unten, up nach oben
function M.addAround(name, pos, radius, down, up)
  local r, d, u = tonumber(radius), tonumber(down) or 0, tonumber(up) or 1
  if not r then return false, "Radius fehlt" end
  return M.add(name, pos.x - r, pos.y - d, pos.z - r, pos.x + r, pos.y + u, pos.z + r)
end

function M.delete(name)
  for i, z in ipairs(data.zones) do
    if z.name == name then
      table.remove(data.zones, i)
      save()
      return true, "Zone " .. name .. " geloescht"
    end
  end
  return false, "Keine Zone namens " .. tostring(name)
end

function M.setMaxY(y)
  y = tonumber(y)
  if not y then return false, "Es braucht eine Zahl" end
  data.maxY = math.floor(y)
  save()
  return true, "Hoehenlimit jetzt Y " .. data.maxY
end

function M.format(z)
  return ("%s: x %d..%d, y %d..%d, z %d..%d"):format(z.name, z.x1, z.x2, z.y1, z.y2, z.z1, z.z2)
end

-- Stand der Zentrale (Map-Dienst) uebernehmen. Ab dann gilt dieser Stand; lokale Aenderungen werden
-- beim naechsten Abgleich ueberschrieben. Geprueft wird weiterhin hier auf der Turtle (check).
function M.replace(zoneList, maxY, rev)
  local list = {}
  for _, z in ipairs(zoneList or {}) do
    list[#list + 1] = {
      name = z.name,
      x1 = math.min(z.x1, z.x2), x2 = math.max(z.x1, z.x2),
      y1 = math.min(z.y1, z.y2), y2 = math.max(z.y1, z.y2),
      z1 = math.min(z.z1, z.z2), z2 = math.max(z.z1, z.z2),
    }
  end
  data.zones = list
  data.maxY = tonumber(maxY) or data.maxY
  data.rev = rev
  save()
end

-- Version des zentralen Stands (0 = Zonen werden nur lokal gepflegt)
function M.rev() return data.rev or 0 end

function M.describe()
  local lines = { "Hoehenlimit: Y " .. data.maxY }
  if data.rev then lines[#lines + 1] = ("Zentral verwaltet (Stand %d), lokale Aenderungen werden ueberschrieben"):format(data.rev) end
  if #data.zones == 0 then
    lines[#lines + 1] = "Keine Mining-Zonen, die Turtle graebt nirgends."
  end
  for _, z in ipairs(data.zones) do lines[#lines + 1] = "Zone " .. M.format(z) end
  return table.concat(lines, "\n")
end

return M
