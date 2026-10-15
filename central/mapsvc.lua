-- mapsvc.lua - Map-Dienst der Zentrale: Zonen, Hoehenlimit und Orte zentral pflegen
--
-- Stammdaten mit Versionsnummer (rev). Worker fragen bei jedem Sync mit ihrer Nummer nach (map.get);
-- nur wenn es etwas Neues gibt, kommt der ganze Stand zurueck (map.data). Die Turtle prueft weiterhin
-- jeden Block lokal mit ihrer Kopie (Whitepaper: Sicherheit lokal).
--
-- Orte: "depot" (gemeinsamer Lagerplatz), "home:<Name>" (Heimplatz einer Turtle), weitere nach Bedarf.
-- Die grosse Weltkarte aus Scans kommt erst in P5; hier nur Stammdaten.
--
-- Topics: map.get, map.zone.add, map.zone.delete, map.maxy, map.place.set, map.place.delete
-- (Aenderungen kommen von der Zentrale selbst oder vom Command-Node nach Bestaetigung durch den Besitzer)

local store = require("store")

local M = {}

local Service = {}
Service.__index = Service

function M.new(host, opts)
  opts = opts or {}
  local self = setmetatable({}, Service)
  self.host = host
  self.dir = opts.dir or "/.central"
  fs.makeDir(self.dir)
  self.file = self.dir .. "/map"
  self.state = store.load(self.file) or { rev = 0, zones = {}, maxY = 50, places = {} }
  self.log = {}
  return self
end

function Service:note(text)
  table.insert(self.log, 1, text)
  while #self.log > 20 do table.remove(self.log) end
end

function Service:changed(text)
  self.state.rev = self.state.rev + 1
  store.save(self.file, self.state)
  self:note(("Karte Stand %d: %s"):format(self.state.rev, text))
end

function Service:addZone(name, x1, y1, z1, x2, y2, z2)
  local v = { tonumber(x1), tonumber(y1), tonumber(z1), tonumber(x2), tonumber(y2), tonumber(z2) }
  for i = 1, 6 do if not v[i] then return nil, "Zone braucht x1 y1 z1 x2 y2 z2" end end
  if type(name) ~= "string" or name == "" then return nil, "Zone braucht einen Namen" end
  self:deleteZone(name, true)
  table.insert(self.state.zones, { name = name, x1 = v[1], y1 = v[2], z1 = v[3], x2 = v[4], y2 = v[5], z2 = v[6] })
  self:changed("Zone " .. name)
  return true
end

function Service:deleteZone(name, quiet)
  for i, z in ipairs(self.state.zones) do
    if z.name == name then
      table.remove(self.state.zones, i)
      if not quiet then self:changed("Zone " .. name .. " geloescht") end
      return true
    end
  end
  return nil, "keine Zone " .. tostring(name)
end

function Service:setMaxY(y)
  y = tonumber(y)
  if not y then return nil, "Hoehenlimit braucht eine Zahl" end
  self.state.maxY = math.floor(y)
  self:changed("Hoehenlimit Y " .. self.state.maxY)
  return true
end

function Service:setPlace(name, x, y, z, f)
  x, y, z = tonumber(x), tonumber(y), tonumber(z)
  if not (x and y and z) or type(name) ~= "string" then return nil, "Ort braucht Name, x, y, z" end
  self.state.places[name] = { x = x, y = y, z = z, f = tonumber(f) or 0 }
  self:changed("Ort " .. name)
  return true
end

function Service:deletePlace(name)
  if not self.state.places[name] then return nil, "kein Ort " .. tostring(name) end
  self.state.places[name] = nil
  self:changed("Ort " .. name .. " geloescht")
  return true
end

function Service:data()
  return { rev = self.state.rev, zones = self.state.zones, maxY = self.state.maxY, places = self.state.places }
end

function Service:handle(msg)
  local p = type(msg.payload) == "table" and msg.payload or {}
  local topic = msg.topic
  local ok, err
  if topic == "map.get" then
    -- full: Turtle startet neu und will die Orte auf jeden Fall (auch bei leerer Karte, Stand 0)
    if p.full or (tonumber(p.rev) or 0) < self.state.rev then
      self.host.send(msg.source, "map.data", self:data(), { reply_to = msg.id })
    end
    return true
  elseif topic == "map.zone.add" then
    ok, err = self:addZone(p.name, p.x1, p.y1, p.z1, p.x2, p.y2, p.z2)
  elseif topic == "map.zone.delete" then
    ok, err = self:deleteZone(p.name)
  elseif topic == "map.maxy" then
    ok, err = self:setMaxY(p.maxy)
  elseif topic == "map.place.set" then
    ok, err = self:setPlace(p.name, p.x, p.y, p.z, p.f)
  elseif topic == "map.place.delete" then
    ok, err = self:deletePlace(p.name)
  else
    return false
  end
  self.host.send(msg.source, "map.changed", { ok = ok == true, error = err, rev = self.state.rev },
    { reply_to = msg.id })
  if ok then self:note(("(von #%s)"):format(tostring(msg.source))) end
  return true
end

function Service:statusLines()
  local lines = { ("Karte Stand %d: %d Zonen, Hoehenlimit Y %d"):format(self.state.rev, #self.state.zones,
    self.state.maxY) }
  local names = {}
  for name in pairs(self.state.places) do names[#names + 1] = name end
  table.sort(names)
  if #names > 0 then lines[#lines + 1] = "Orte: " .. table.concat(names, ", ") end
  return lines
end

return M
