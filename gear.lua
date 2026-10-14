-- gear.lua - Ausruestung (Geo Scanner, Player Detector, Modem ...) kurz anlegen und wieder ablegen
-- Die Chat Box bleibt immer dran. Getauscht wird die andere Seite (die Spitzhacke):
-- Peripheral rein, benutzen, Spitzhacke wieder rein.
-- Die Ausruestungskiste steht UNTER dem Heimplatz.

local M = {}

-- Kurznamen -> Teil des Itemnamens
M.ITEMS = {
  geo_scanner = "geo_scanner",
  player_detector = "player_detector",
  modem = "modem",
  pickaxe = "pickaxe",
  environment_detector = "environment_detector",
}

-- Gegenstaende, die zur Ausruestung gehoeren und nie ausgeladen werden
function M.isGear(name)
  return name:find("advancedperipherals:", 1, true) ~= nil or name:find("modem", 1, true) ~= nil
    or name:find("pickaxe", 1, true) ~= nil or name == "minecraft:chest" -- Zwischenkiste fuers Minen
end

function M.findSlot(pattern)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name:find(pattern, 1, true) then return slot end
  end
end

-- Wireless/Ender Modem fest ausgeruestet?
function M.wirelessEquipped()
  for _, side in ipairs({ "left", "right" }) do
    if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then return side end
  end
end

-- Was ist auf einer Seite ausgeruestet? Itemname, "" fuer leer, nil wenn die CC-Version das nicht verraet
local function equipped(side)
  local fn = side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
  if not fn then return nil end
  local item = fn()
  if item == nil then return "" end
  if type(item) == "table" and item.name then return item.name end
  return nil
end

-- Spitzhacke ausgeruestet? Seite oder nil
function M.pickaxeSide()
  for _, side in ipairs({ "left", "right" }) do
    local name = equipped(side)
    if name and name:find("pickaxe", 1, true) then return side end
  end
end

-- Hat die Turtle das Teil? Im Inventar oder (Modem, Spitzhacke) fest ausgeruestet
function M.has(pattern)
  if M.findSlot(pattern) then return true end
  if pattern == "modem" then return M.wirelessEquipped() ~= nil end
  if pattern == "pickaxe" then
    if M.pickaxeSide() then return true end
    -- aeltere CC-Version ohne getEquipped*: nicht pruefbar, als vorhanden annehmen
    return turtle.getEquippedLeft == nil
  end
  return false
end

-- Seiten, die nie getauscht werden: Chat Box und Funkmodem (sonst kein Chat bzw. kein Funk)
local function fixed(side)
  local t = peripheral.getType(side)
  if t == "chatBox" then return true end
  return t == "modem" and peripheral.call(side, "isWireless") == true
end

-- Seite fuer den Tausch
local function toolSide()
  if fixed("left") then return "right" end
  if fixed("right") then return "left" end
  return M.pickaxeSide() or "left"
end

-- Spitzhacke aus dem Inventar anlegen, falls keine dran ist (auf der Seite ohne Modem/Chat Box)
function M.equipPickaxe()
  if M.pickaxeSide() then return true end
  local slot = M.findSlot("pickaxe")
  if not slot then return false, "keine Spitzhacke dabei (liegt sie daheim in der Toolbox?)" end
  local side = toolSide()
  local sel = turtle.getSelectedSlot()
  turtle.select(slot)
  local ok = (side == "left" and turtle.equipLeft or turtle.equipRight)()
  turtle.select(sel)
  if not ok then return false, "Spitzhacke laesst sich nicht anlegen" end
  return true
end

-- Legt das Item kurz an, ruft fn(peripheral) auf und legt danach wieder die alte Ausruestung an.
function M.with(pattern, fn)
  local slot = M.findSlot(pattern)
  if not slot then return nil, "kein " .. pattern .. " im Inventar (Ausruestung holen?)" end
  local side = toolSide()
  local equip = side == "left" and turtle.equipLeft or turtle.equipRight
  local sel = turtle.getSelectedSlot()

  turtle.select(slot)
  if not equip() then
    turtle.select(sel)
    return nil, pattern .. " laesst sich nicht als Turtle-Upgrade anlegen"
  end
  local p
  for _ = 1, 10 do
    p = peripheral.wrap(side)
    if p then break end
    sleep(0.1)
  end

  local res = table.pack(pcall(fn, p))
  turtle.select(slot)
  equip() -- alte Ausruestung (Spitzhacke) wieder an
  turtle.select(sel)

  if not p then return nil, pattern .. " wurde nicht erkannt" end
  if not res[1] then return nil, tostring(res[2]) end
  return table.unpack(res, 2, res.n)
end

-- Position eines Spielers: Player Detector als Block neben der Turtle oder aus dem Inventar
function M.playerPos(name)
  local function ask(det)
    local pos = det.getPlayerPos and det.getPlayerPos(name)
    if not pos and det.getPlayer then pos = det.getPlayer(name) end
    return pos
  end
  local block = peripheral.find("playerDetector") or peripheral.find("player_detector")
  if block then
    local pos = ask(block)
    if pos then return pos end
  end
  local pos, err = M.with("player_detector", ask)
  if not pos then return nil, err or ("Spieler " .. tostring(name) .. " nicht gefunden") end
  return pos
end

local function chestBelow()
  local p = peripheral.wrap("bottom")
  if p and p.list then return p end
end

-- Inhalt der Ausruestungskiste und was die Turtle dabei hat
function M.describe()
  local lines = {}
  local chest = chestBelow()
  if chest then
    local items = {}
    for _, item in pairs(chest.list()) do items[#items + 1] = item.name:gsub("^[%w_]+:", "") end
    lines[#lines + 1] = "In der Ausruestungskiste: " .. (#items > 0 and table.concat(items, ", ") or "nichts")
  else
    lines[#lines + 1] = "Keine Ausruestungskiste unter der Turtle (nur am Heimplatz sichtbar)."
  end
  local carried = {}
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and M.isGear(item.name) then carried[#carried + 1] = item.name:gsub("^[%w_]+:", "") end
  end
  lines[#lines + 1] = "Dabei: " .. (#carried > 0 and table.concat(carried, ", ") or "nichts")
  return table.concat(lines, "\n")
end

-- Holt die gewuenschten Teile aus der Kiste unten. wanted = Liste von Kurznamen (siehe M.ITEMS).
function M.take(wanted)
  if not chestBelow() then return false, "Keine Ausruestungskiste unter mir, erst heimfahren." end
  local want = {}
  for _, w in ipairs(wanted or {}) do want[M.ITEMS[w] or w] = true end

  local before = {}
  for slot = 1, 16 do before[slot] = turtle.getItemCount(slot) end
  local sel = turtle.getSelectedSlot()
  for _ = 1, 16 do
    if not turtle.suckDown() then break end
  end

  -- alles Neue, das nicht gewuenscht ist, zurueck in die Kiste
  local got = {}
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and turtle.getItemCount(slot) > before[slot] then
      local keep = false
      for pattern in pairs(want) do
        if item.name:find(pattern, 1, true) and not got[pattern] then
          keep, got[pattern] = true, true
        end
      end
      if not keep then
        turtle.select(slot)
        turtle.dropDown()
      end
    end
  end
  turtle.select(sel)

  local missing = {}
  for pattern in pairs(want) do
    if not got[pattern] and not M.findSlot(pattern) then missing[#missing + 1] = pattern end
  end
  if #missing > 0 then return false, "Nicht in der Kiste: " .. table.concat(missing, ", ") end
  return true, "Ausruestung geholt. " .. M.describe()
end

-- Legt alle Ausruestung (ausser Chat Box und Ersatz-Spitzhacke) zurueck in die Kiste
function M.store()
  if not chestBelow() then return false, "Keine Ausruestungskiste unter mir, erst heimfahren." end
  local sel = turtle.getSelectedSlot()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and M.isGear(item.name) and not item.name:find("chat_box", 1, true)
      and not item.name:find("pickaxe", 1, true) then
      turtle.select(slot)
      turtle.dropDown()
    end
  end
  turtle.select(sel)
  return true, "Ausruestung zurueckgelegt. " .. M.describe()
end

-- Was liegt in der Toolbox unter der Turtle? { geo_scanner = true, chest = true, ... } oder nil (keine Kiste)
function M.toolboxContents()
  local chest = chestBelow()
  if not chest then return nil end
  local found = {}
  for _, item in pairs(chest.list()) do
    local n = item.name
    if n:find("geo_scanner", 1, true) then found.geo_scanner = true
    elseif n:find("player_detector", 1, true) then found.player_detector = true
    elseif n:find("modem", 1, true) then found.modem = true
    elseif n:find("pickaxe", 1, true) then found.pickaxe = true
    elseif n == "minecraft:chest" then found.chest = true end
  end
  return found
end

return M
