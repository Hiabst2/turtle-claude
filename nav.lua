-- nav.lua - Bewegung mit Positionsspeicher, Fuel, Inventar, Heimweg und GPS
-- Wird von claude.lua und den Mining-Programmen per require("nav") geladen.
-- Die Position wird in /.nav gespeichert und ueberlebt Neustarts.

local zones = require("zones")
local gear = require("gear")

local M = {}

local STATE_FILE = "/.nav"
-- Richtungen wie in Minecraft: 0 = Sued (+z), 1 = West (-x), 2 = Nord (-z), 3 = Ost (+x).
-- turnRight erhoeht f um 1. Ohne GPS ist "Sued" einfach die Startrichtung.
local DX = { [0] = 0, -1, 0, 1 }
local DZ = { [0] = 1, 0, -1, 0 }
local WORLD_DIRS = { [0] = "Sued", "West", "Nord", "Ost" }
local REL_DIRS = { [0] = "Startrichtung", "rechts", "hinten", "links" }

M.HOME_ORDER = "xzy"
M.DX, M.DZ = DX, DZ
M.stats = { blocks = 0 }

local state

local function save()
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialize(state))
  f.close()
end

if fs.exists(STATE_FILE) then
  local f = fs.open(STATE_FILE, "r")
  state = textutils.unserialize(f.readAll())
  f.close()
end
if not state then
  state = { pos = { x = 0, y = 0, z = 0, f = 0 }, home = { x = 0, y = 0, z = 0, f = 0 }, gps = false }
  save()
end

function M.pos() return state.pos end
function M.home() return state.home end
-- Lagerplatz zum Ausladen und Tanken. Ohne eigenen Lagerplatz ist es der Heimplatz.
function M.depot() return state.depot or state.home end
function M.hasGps() return state.gps end

local function fmt(p)
  return ("x=%d y=%d z=%d"):format(p.x, p.y, p.z)
end

function M.where()
  local p, h = state.pos, state.home
  local dirs = state.gps and WORLD_DIRS or REL_DIRS
  return ("Position %s, Blick %s | Zuhause %s%s%s"):format(fmt(p), dirs[p.f], fmt(h),
    state.depot and (" | Lager " .. fmt(state.depot)) or "",
    state.gps and " (GPS-Weltkoordinaten)" or " (relativ zum Start, kein GPS)")
end

function M.dist(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

-- Abbruch per "stop" aus dem Chat
local aborted = false
function M.abort() aborted = true end
function M.resetAbort() aborted = false end
function M.check()
  if aborted then
    aborted = false
    error("abgebrochen", 0)
  end
end

-- Fuel ------------------------------------------------------------------

local FUEL = {
  ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true,
  ["minecraft:lava_bucket"] = true, ["minecraft:blaze_rod"] = true,
}
function M.isFuel(name) return FUEL[name] == true end

function M.fuel()
  local level = turtle.getFuelLevel()
  if level == "unlimited" then return math.huge end
  return level
end

-- Verbrennt nur echte Brennstoffe (kein Holz, keine Truhen), bis target erreicht ist.
function M.refuel(target)
  target = math.min(target or math.huge, turtle.getFuelLimit() == "unlimited" and math.huge or turtle.getFuelLimit())
  local sel = turtle.getSelectedSlot()
  for slot = 1, 16 do
    if M.fuel() >= target then break end
    local item = turtle.getItemDetail(slot)
    if item and FUEL[item.name] then
      turtle.select(slot)
      while M.fuel() < target and turtle.getItemCount(slot) > 0 and turtle.refuel(1) do end
    end
  end
  turtle.select(sel)
  return M.fuel()
end

local function ensureFuel(n)
  if M.fuel() < n then M.refuel(n + 200) end
  if M.fuel() < n then error("kein Fuel mehr", 0) end
end

-- Graben ----------------------------------------------------------------

local DIG = {
  front = { turtle.detect, turtle.dig, turtle.inspect },
  up = { turtle.detectUp, turtle.digUp, turtle.inspectUp },
  down = { turtle.detectDown, turtle.digDown, turtle.inspectDown },
}

local function falls(name)
  return name:find("gravel") or name:find("sand") or name:find("concrete_powder")
end

-- Koordinate des Blocks vorne/oben/unten
function M.target(dir)
  local p = state.pos
  if dir == "up" then return { x = p.x, y = p.y + 1, z = p.z } end
  if dir == "down" then return { x = p.x, y = p.y - 1, z = p.z } end
  return { x = p.x + DX[p.f], y = p.y, z = p.z + DZ[p.f] }
end

-- Graebt in eine Richtung, auch wenn Kies oder Sand nachrutscht.
-- Jeder Abbau wird gegen Zonen, Hoehenlimit und geschuetzte Bloecke geprueft.
function M.dig(dir)
  dir = dir or "front"
  local detect, dig, inspect = table.unpack(DIG[dir])
  for _ = 1, 30 do
    if not detect() then return true end
    local found, data = inspect()
    local allowed, why = zones.check(M.target(dir), found and data.name or nil, state.gps)
    if not allowed then return false, "Darf hier nicht graben: " .. why end
    local ok, why = dig()
    if not ok then return false, why or "nicht abbaubar" end
    M.stats.blocks = M.stats.blocks + 1
    if type(data) == "table" and falls(data.name) then sleep(0.5) end
  end
  return false, "es rutscht immer wieder etwas nach"
end

-- Bewegung --------------------------------------------------------------

local function moved(dx, dy, dz)
  local p = state.pos
  p.x, p.y, p.z = p.x + dx, p.y + dy, p.z + dz
  save()
end

local function go(move, dir, attack, dig, onOk)
  local detect = DIG[dir][1]
  for _ = 1, 30 do
    M.check()
    ensureFuel(1)
    if move() then onOk(); return true end
    if detect() then
      if not dig then return false, "Block im Weg" end
      local ok, why = M.dig(dir)
      if not ok then return false, why end
    else
      attack() -- Mob im Weg
    end
  end
  return false, "komme nicht weiter"
end

function M.forward(dig)
  return go(turtle.forward, "front", turtle.attack, dig, function()
    moved(DX[state.pos.f], 0, DZ[state.pos.f])
  end)
end

function M.up(dig)
  return go(turtle.up, "up", turtle.attackUp, dig, function() moved(0, 1, 0) end)
end

function M.down(dig)
  return go(turtle.down, "down", turtle.attackDown, dig, function() moved(0, -1, 0) end)
end

function M.turnLeft()
  turtle.turnLeft()
  state.pos.f = (state.pos.f + 3) % 4
  save()
  return true
end

function M.turnRight()
  turtle.turnRight()
  state.pos.f = (state.pos.f + 1) % 4
  save()
  return true
end

function M.turnAround()
  M.turnRight()
  return M.turnRight()
end

function M.back(dig)
  M.check()
  ensureFuel(1)
  if turtle.back() then
    moved(-DX[state.pos.f], 0, -DZ[state.pos.f])
    return true
  end
  if not dig then return false, "hinten blockiert" end
  M.turnAround()
  local ok, err = M.forward(true)
  M.turnAround()
  return ok, err
end

function M.face(f)
  local d = (f - state.pos.f) % 4
  if d == 1 then M.turnRight() elseif d == 2 then M.turnAround() elseif d == 3 then M.turnLeft() end
end

-- Faehrt Achse fuer Achse zum Ziel, z.B. order = "xzy". Graebt sich standardmaessig durch.
function M.goTo(x, y, z, order, dig)
  if dig == nil then dig = true end
  local p = state.pos
  for axis in (order or M.HOME_ORDER):gmatch(".") do
    if axis == "y" then
      while p.y < y do local ok, e = M.up(dig); if not ok then return false, e end end
      while p.y > y do local ok, e = M.down(dig); if not ok then return false, e end end
    else
      local target = axis == "x" and x or z
      local function cur() return axis == "x" and p.x or p.z end
      if cur() ~= target then
        if axis == "x" then M.face(target > cur() and 3 or 1) else M.face(target > cur() and 0 or 2) end
        while cur() ~= target do
          local ok, e = M.forward(dig)
          if not ok then return false, e end
        end
      end
    end
  end
  return true
end

-- Ohne Angabe die aktuelle Position, sonst p = { x, y, z, f } (f wie in DX/DZ)
function M.setHome(p)
  p = p or state.pos
  state.home = { x = p.x, y = p.y, z = p.z, f = p.f }
  save()
end

-- Lagerplatz: hinter der Turtle der Cable Connector, unter oder neben ihr der Kohle-Connector
function M.setDepot(p)
  p = p or state.pos
  state.depot = { x = p.x, y = p.y, z = p.z, f = p.f }
  save()
end

-- Weite Wege: erst hoch auf Reisehoehe, oben rueber, dann runter. So wird unterwegs nichts umgegraben
-- (und ausserhalb der Zonen darf sie sowieso nicht graben). Kurze Wege direkt mit goTo.
M.TRAVEL_Y = settings.get("claude.travel_y", 110)

local function far(x, z)
  return math.abs(state.pos.x - x) + math.abs(state.pos.z - z) > 8
end

local function climb(x, z)
  local p = state.pos
  local ty = math.max(M.TRAVEL_Y, p.y)
  local ok, err = M.goTo(p.x, ty, p.z, "y")
  if not ok then return false, "Weg nach oben blockiert: " .. err end
  ok, err = M.goTo(x, ty, z, "xz")
  if not ok then return false, "Weg in Reisehoehe blockiert: " .. err end
  return true
end

function M.travel(x, y, z, order)
  if not far(x, z) then return M.goTo(x, y, z, order or M.HOME_ORDER) end
  local ok, err = climb(x, z)
  if not ok then return false, err end
  return M.goTo(x, y, z, "y")
end

-- Zu einer Stelle fliegen und von oben herabsinken, bis Boden kommt oder Hoehe y erreicht ist.
-- Gegraben wird beim Herabsinken nicht.
function M.approach(x, y, z)
  local ok, err = climb(x, z)
  if not ok then return false, err end
  while state.pos.y > y do
    if not M.down(false) then break end
  end
  return true
end

function M.goHome(order)
  local h = state.home
  local ok, err = M.travel(h.x, h.y, h.z, order)
  if ok then M.face(h.f) end
  return ok, err
end

function M.goDepot(order)
  local d = M.depot()
  local ok, err = M.travel(d.x, d.y, d.z, order)
  if ok then M.face(d.f) end
  return ok, err
end

-- Inventar --------------------------------------------------------------

local function keep(name)
  return name:find("chat_box", 1, true) or gear.isGear(name)
end

local JUNK = {}
for _, n in ipairs({ "cobblestone", "cobbled_deepslate", "dirt", "gravel", "stone", "deepslate", "tuff",
  "granite", "diorite", "andesite", "netherrack", "calcite", "flint", "sand", "sandstone" }) do
  JUNK["minecraft:" .. n] = true
end

function M.freeSlots()
  local n = 0
  for slot = 1, 16 do if turtle.getItemCount(slot) == 0 then n = n + 1 end end
  return n
end

function M.dropJunk()
  local sel = turtle.getSelectedSlot()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and JUNK[item.name] then
      turtle.select(slot)
      turtle.dropUp()
    end
  end
  turtle.select(sel)
end

-- Leert das Inventar in die Truhe bzw. ins Lager hinter dem Lagerplatz.
-- Behalten werden die Ausruestung (Chat Box, Spitzhacke, Peripherals) und ein Stapel Kohle.
-- Fehlt danach noch Fuel oder Reserve, holt restock() Kohle aus dem Lager.
function M.unload()
  local h = M.depot()
  M.face((h.f + 2) % 4)
  local ok, data = turtle.inspect()
  local name = ok and data.name or ""
  -- Truhe oder Tom's Storage Cable Connector (dann landet alles direkt im Lager)
  if not (name:find("chest") or name:find("barrel") or name:find("shulker") or name:find("toms_storage")) then
    M.face(h.f)
    return false, "hinter dem Lagerplatz steht keine Truhe und kein Lager-Anschluss"
  end
  -- Eigene Kohle zuerst verbrennen und bis zu einem Stapel behalten, nur der Rest kommt ins Lager.
  -- So wandert keine Kohle sinnlos ins Lager und gleich wieder zurueck.
  M.refuel(M.FUEL_TARGET)
  local sel, dropped, full, reserve = turtle.getSelectedSlot(), 0, false, 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not keep(item.name) then
      local count = item.count
      if FUEL[item.name] and reserve < 64 then
        local kept = math.min(count, 64 - reserve)
        reserve, count = reserve + kept, count - kept
      end
      if count > 0 then
        turtle.select(slot)
        if turtle.drop(count) then dropped = dropped + count else full = true end
      end
    end
  end
  turtle.select(sel)
  M.face(h.f)
  M.restock()
  if full then return false, "Truhe ist voll" end
  return true, dropped
end

-- Kohle nachfuellen am Lagerplatz: unter, links oder rechts steht ein Filtered Cable Connector (Tom's Storage,
-- Filter auf Kohle) oder eine Truhe mit Kohle. Tankt bis FUEL_TARGET und nimmt einen Stapel als Reserve mit.
M.FUEL_TARGET = settings.get("claude.fuel_target", 5000)

local function fuelItems()
  local n = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and FUEL[item.name] then n = n + item.count end
  end
  return n
end

local function freeSlot()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then return slot end
  end
end

function M.restock()
  local h, p = M.depot(), state.pos
  if p.x ~= h.x or p.y ~= h.y or p.z ~= h.z then return 0 end
  local target = math.min(M.FUEL_TARGET, turtle.getFuelLimit() == "unlimited" and math.huge or turtle.getFuelLimit())
  local sel, got = turtle.getSelectedSlot(), 0

  local function pull(suck, drop)
    for _ = 1, 4 do
      if M.fuel() >= target and fuelItems() >= 64 then return end
      local slot = freeSlot()
      if not slot then return end
      turtle.select(slot)
      if not suck(64) then return end
      local item = turtle.getItemDetail(slot)
      if not (item and FUEL[item.name]) then
        drop() -- kein Brennstoff, zurueck damit
        return
      end
      got = got + item.count
      if M.fuel() < target then M.refuel(target) end
    end
  end

  -- Kohle-Connector unter der Turtle
  local okDown, below = turtle.inspectDown()
  if okDown and below.name:find("connector_filtered") then pull(turtle.suckDown, turtle.dropDown) end

  -- oder links/rechts (Filtered Connector oder Truhe mit Kohle)
  for _, f in ipairs({ (h.f + 1) % 4, (h.f + 3) % 4 }) do
    if M.fuel() >= target and fuelItems() >= 64 then break end
    M.face(f)
    local ok, data = turtle.inspect()
    local name = ok and data.name or ""
    if name:find("connector_filtered") or name:find("chest") or name:find("barrel") then
      pull(turtle.suck, turtle.drop)
    end
  end
  turtle.select(sel)
  M.face(h.f)
  return got
end

-- GPS -------------------------------------------------------------------

local function wirelessSide()
  for _, side in ipairs({ "left", "right" }) do
    if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then return side end
  end
end

-- Modem kurz statt der Spitzhacke anlegen (die Chat Box bleibt dran)
function M.locate()
  local x, y, z
  if wirelessSide() then
    x, y, z = gps.locate(2)
  else
    local ok, err = gear.with("modem", function() x, y, z = gps.locate(2) return true end)
    if not ok then return nil, err end
  end
  if not x then return nil, "kein GPS-Signal (laufen die 4 GPS-Computer? Modem in Reichweite?)" end
  return { x = x, y = y, z = z }
end

-- Stellt Position und Heimplatz auf echte Weltkoordinaten um.
function M.calibrate()
  local p1, err = M.locate()
  if not p1 then return false, err end

  -- Blickrichtung: einen Block in eine freie Richtung fahren und nochmal messen
  local turns = 0
  while turtle.detect() and turns < 4 do M.turnRight(); turns = turns + 1 end
  if turns == 4 or not M.forward(false) then return false, "rundherum zu, kann die Richtung nicht messen" end
  local p2, err2 = M.locate()
  M.back(true)
  if not p2 then return false, err2 end

  local wf
  if p2.x > p1.x then wf = 3 elseif p2.x < p1.x then wf = 1 elseif p2.z > p1.z then wf = 0 else wf = 2 end

  -- Heimplatz aus dem alten System ins Weltsystem drehen und verschieben
  local p, h = state.pos, state.home
  local k = (wf - p.f) % 4
  local function convert(t)
    local vx, vz = t.x - p.x, t.z - p.z
    for _ = 1, k do vx, vz = -vz, vx end
    return { x = p1.x + vx, y = p1.y + (t.y - p.y), z = p1.z + vz, f = (t.f + k) % 4 }
  end
  state.home = convert(h)
  if state.depot then state.depot = convert(state.depot) end
  p.x, p.y, p.z, p.f = p1.x, p1.y, p1.z, wf
  state.gps = true
  save()
  return true
end

return M
