-- path.lua - Wegsuche, die moeglichst wenig Stein abbaut
-- Eine Karte merkt sich, was die Turtle weiss: Luft (Hoehlen, eigene Gaenge), Erz, Stein, Verbotenes.
-- Gefuellt wird sie vom Geo Scanner und von jedem Schritt der Turtle. Der Weg wird mit A* gesucht:
-- Luft und Erz kosten 1, Stein (und alles Unbekannte) 1 + STONE, Verbotenes ist unpassierbar.

local nav = require("nav")
local zones = require("zones")

local M = {}

M.STONE = 8 -- Zusatzkosten pro Steinblock: lieber 8 Bloecke Umweg durch Luft als 1 Stein graben

local function key(x, y, z) return x .. "," .. y .. "," .. z end
M.key = key

function M.newMap()
  return { cells = {}, ores = {}, zone = {}, min = nil, max = nil }
end

local function grow(map, x, y, z)
  if not map.min then
    map.min, map.max = { x = x, y = y, z = z }, { x = x, y = y, z = z }
    return
  end
  local a, b = map.min, map.max
  if x < a.x then a.x = x end
  if y < a.y then a.y = y end
  if z < a.z then a.z = z end
  if x > b.x then b.x = x end
  if y > b.y then b.y = y end
  if z > b.z then b.z = z end
end

function M.set(map, x, y, z, kind, name)
  local k = key(x, y, z)
  map.cells[k] = kind
  map.ores[k] = kind == "ore" and name or nil
  grow(map, x, y, z)
end

function M.markAir(map, p)
  M.set(map, p.x, p.y, p.z, "air")
end

local function classify(b, isOre)
  local name = b.name
  if name:find("air", 1, true) and not name:find("stair", 1, true) then return "air" end
  if name:find("water", 1, true) or name:find("lava", 1, true) then return "air" end -- Turtles schwimmen durch
  if name:find("bedrock", 1, true) or zones.isProtected(name) then return "block" end
  if isOre(b) then return "ore" end
  return "solid"
end

-- Scan-Ergebnis in die Karte eintragen. Alles im Scanradius, was nicht gelistet ist, ist Luft.
function M.addScan(map, origin, radius, blocks, isOre)
  local r2 = radius * radius
  for dx = -radius, radius do
    for dy = -radius, radius do
      for dz = -radius, radius do
        if dx * dx + dy * dy + dz * dz <= r2 then
          local k = key(origin.x + dx, origin.y + dy, origin.z + dz)
          if not map.cells[k] then M.set(map, origin.x + dx, origin.y + dy, origin.z + dz, "air") end
        end
      end
    end
  end
  for _, b in ipairs(blocks) do
    local kind = classify(b, isOre)
    -- Erz ausserhalb der Zonen wird wie Stein behandelt (nicht abbauen, nicht ansteuern)
    if kind == "ore" and not zones.check(b, b.name, nav.hasGps()) then kind = "solid" end
    M.set(map, b.x, b.y, b.z, kind, b.name)
  end
  M.markAir(map, nav.pos())
end

-- Was kostet es, die Zelle zu betreten? nil = gar nicht
local function cost(map, x, y, z)
  local k = key(x, y, z)
  local c = map.cells[k]
  if c == "air" or c == "ore" then return 1 end
  if c == "block" then return nil end
  -- Stein oder unbekannt: nur wenn dort gegraben werden darf
  local ok = map.zone[k]
  if ok == nil then
    ok = zones.check({ x = x, y = y, z = z }, nil, nav.hasGps()) and true or false
    map.zone[k] = ok
  end
  return ok and (1 + M.STONE) or nil
end

-- kleiner Binaer-Heap nach f
local function push(heap, node)
  heap[#heap + 1] = node
  local i = #heap
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap[parent].f <= heap[i].f then break end
    heap[parent], heap[i] = heap[i], heap[parent]
    i = parent
  end
end

local function pop(heap)
  local top, last = heap[1], table.remove(heap)
  if #heap > 0 then
    heap[1] = last
    local i = 1
    while true do
      local l, r, s = 2 * i, 2 * i + 1, i
      if heap[l] and heap[l].f < heap[s].f then s = l end
      if heap[r] and heap[r].f < heap[s].f then s = r end
      if s == i then break end
      heap[s], heap[i] = heap[i], heap[s]
      i = s
    end
  end
  return top
end

-- CC bricht Programme ab, die zu lange nicht pausieren
local function breathe()
  os.queueEvent("path_yield")
  os.pullEvent("path_yield")
end

local NEIGHBORS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 } }

-- Sucht den billigsten Weg von from zu einer Zelle, fuer die isGoal(x, y, z, k) true ist.
-- h(x, y, z) = Schaetzung der Restkosten (0 = Dijkstra). Gibt die Liste der Schritte zurueck.
local function search(map, from, isGoal, h, pad, extra)
  local lo, hi = map.min or from, map.max or from
  local bx1, by1, bz1 = math.min(lo.x, from.x), math.min(lo.y, from.y), math.min(lo.z, from.z)
  local bx2, by2, bz2 = math.max(hi.x, from.x), math.max(hi.y, from.y), math.max(hi.z, from.z)
  if extra then
    bx1, by1, bz1 = math.min(bx1, extra.x), math.min(by1, extra.y), math.min(bz1, extra.z)
    bx2, by2, bz2 = math.max(bx2, extra.x), math.max(by2, extra.y), math.max(bz2, extra.z)
  end
  bx1, by1, bz1, bx2, by2, bz2 = bx1 - pad, by1 - pad, bz1 - pad, bx2 + pad, by2 + pad, bz2 + pad

  local startK = key(from.x, from.y, from.z)
  local dist, prev, pos = { [startK] = 0 }, {}, { [startK] = { from.x, from.y, from.z } }
  local heap = {}
  push(heap, { k = startK, x = from.x, y = from.y, z = from.z, g = 0, f = h(from.x, from.y, from.z) })
  local n = 0
  while #heap > 0 do
    local node = pop(heap)
    if node.g == dist[node.k] then
      if node.k ~= startK and isGoal(node.x, node.y, node.z, node.k) then
        local steps, k = {}, node.k
        while k ~= startK do
          table.insert(steps, 1, pos[k])
          k = prev[k]
        end
        return steps, node.g
      end
      for _, d in ipairs(NEIGHBORS) do
        local x, y, z = node.x + d[1], node.y + d[2], node.z + d[3]
        if x >= bx1 and x <= bx2 and y >= by1 and y <= by2 and z >= bz1 and z <= bz2 then
          local c = cost(map, x, y, z)
          if c then
            local k, g = key(x, y, z), node.g + c
            if not dist[k] or g < dist[k] then
              dist[k], prev[k], pos[k] = g, node.k, { x, y, z }
              push(heap, { k = k, x = x, y = y, z = z, g = g, f = g + h(x, y, z) })
            end
          end
        end
      end
      n = n + 1
      if n % 1500 == 0 then breathe() end
    end
  end
  return nil
end

local function face(dx, dz)
  if dx == 1 then nav.face(3) elseif dx == -1 then nav.face(1) elseif dz == 1 then nav.face(0) else nav.face(2) end
end

-- Geht die Schritte ab. onOre(name) wird fuer jedes Erz aufgerufen, das dabei abgebaut wird.
local function follow(map, steps, onOre)
  for _, s in ipairs(steps) do
    local p = nav.pos()
    local x, y, z = s[1], s[2], s[3]
    local k = key(x, y, z)
    local ore = map.ores[k]
    local ok, err
    if y > p.y then ok, err = nav.up(true)
    elseif y < p.y then ok, err = nav.down(true)
    else
      face(x - p.x, z - p.z)
      ok, err = nav.forward(true)
    end
    if not ok then
      M.set(map, x, y, z, "block") -- beim naechsten Planen aussen herum
      return false, err
    end
    if ore and onOre then onOre(ore) end
    M.markAir(map, nav.pos())
  end
  return true
end

-- Zu einem Ziel, so steinsparend wie moeglich. Plant bei Hindernissen bis zu 5x neu.
function M.go(map, target, onOre)
  for _ = 1, 5 do
    local p = nav.pos()
    if p.x == target.x and p.y == target.y and p.z == target.z then return true end
    local steps = search(map, p, function(x, y, z) return x == target.x and y == target.y and z == target.z end,
      function(x, y, z) return math.abs(x - target.x) + math.abs(y - target.y) + math.abs(z - target.z) end,
      3, target)
    if not steps then return false, "Darf hier nicht graben: kein erlaubter Weg zum Ziel" end
    local ok, err = follow(map, steps, onOre)
    if ok then return true end
    if not tostring(err):find("Darf hier nicht graben", 1, true) then return false, err end
  end
  return false, "Darf hier nicht graben: Weg immer wieder blockiert"
end

-- Zum Erz, das am wenigsten Stein kostet. Gibt false zurueck, wenn keins mehr erreichbar ist.
function M.nextOre(map, onOre)
  local p = nav.pos()
  local steps = search(map, p, function(_, _, _, k) return map.ores[k] ~= nil end,
    function() return 0 end, 1)
  if not steps then return false end
  local ok, err = follow(map, steps, onOre)
  if not ok and not tostring(err):find("Darf hier nicht graben", 1, true) then error(err, 0) end
  return true
end

return M
