-- colony.lua - liest MineColonies ueber den Colony Integrator (Advanced Peripherals)
-- Der Integrator muss in der Kolonie stehen und direkt an die Turtle grenzen (am besten am Heimplatz).
-- Alle Funktionen liefern kompakten Text, damit Claude wenig Tokens braucht.

local M = {}

local function find()
  return peripheral.find("colonyIntegrator") or peripheral.find("colony_integrator")
end

-- Macht aus verschachtelten Werten einen kurzen Namen
local function label(v)
  if type(v) ~= "table" then return tostring(v) end
  return tostring(v.displayName or v.name or v.type or v.job or "?")
end

local function short(name)
  return (tostring(name):gsub("^[%w_]+:", ""))
end

local function num(v, digits)
  if type(v) ~= "number" then return "?" end
  return ("%." .. (digits or 1) .. "f"):format(v)
end

local function call(c, fn, ...)
  local ok, res = pcall(c[fn], ...)
  if ok then return res end
  return nil
end

local function overview(c)
  local lines = {
    ("Kolonie: %s (ID %s)"):format(tostring(call(c, "getColonyName")), tostring(call(c, "getColonyID"))),
    ("Buerger: %s / %s, Zufriedenheit: %s / 10"):format(tostring(call(c, "amountOfCitizens")),
      tostring(call(c, "maxOfCitizens")), num(call(c, "getHappiness"))),
    ("Baustellen: %s, Graeber: %s"):format(tostring(call(c, "amountOfConstructionSites")),
      tostring(call(c, "amountOfGraves"))),
  }
  if call(c, "isUnderAttack") then lines[#lines + 1] = "ACHTUNG: Die Kolonie wird angegriffen!" end
  local requests = call(c, "getRequests") or {}
  local orders = call(c, "getWorkOrders") or {}
  lines[#lines + 1] = ("Offene Anfragen: %d, Bauauftraege: %d"):format(#requests, #orders)
  local idle = 0
  for _, cit in ipairs(call(c, "getCitizens") or {}) do
    if cit.isIdle then idle = idle + 1 end
  end
  if idle > 0 then lines[#lines + 1] = ("Untaetige Buerger: %d"):format(idle) end
  return table.concat(lines, "\n")
end

local function requests(c)
  local list = call(c, "getRequests") or {}
  if #list == 0 then return "Keine offenen Anfragen." end
  local lines = {}
  for _, r in ipairs(list) do
    lines[#lines + 1] = ("- %s x%s fuer %s [%s]"):format(label(r.name or r.desc), tostring(r.count or "?"),
      label(r.target or "?"), label(r.state or "?"))
  end
  return table.concat(lines, "\n")
end

local function citizens(c)
  local list = call(c, "getCitizens") or {}
  if #list == 0 then return "Keine Buerger." end
  local lines = {}
  for _, cit in ipairs(list) do
    local flags = {}
    if cit.isIdle then flags[#flags + 1] = "untaetig" end
    if cit.isAsleep then flags[#flags + 1] = "schlaeft" end
    if not cit.home then flags[#flags + 1] = "kein Haus" end
    if type(cit.saturation) == "number" and cit.saturation < 5 then flags[#flags + 1] = "hungrig" end
    if cit.betterFood then flags[#flags + 1] = "will besseres Essen" end
    lines[#lines + 1] = ("- %s: %s, Zufr. %s, Hunger %s/20, HP %s/%s%s%s"):format(
      tostring(cit.name), cit.work and label(cit.work) or "arbeitslos", num(cit.happiness), num(cit.saturation, 0),
      num(cit.health, 0), num(cit.maxHealth, 0),
      cit.state and (", " .. label(cit.state)) or "", #flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or "")
  end
  return table.concat(lines, "\n")
end

local function buildings(c)
  local list = call(c, "getBuildings") or {}
  if #list == 0 then return "Keine Gebaeude." end
  local lines = {}
  for _, b in ipairs(list) do
    local flags = {}
    if b.built == false then flags[#flags + 1] = "nicht fertig" end
    if b.isWorkingOn then flags[#flags + 1] = "wird gebaut" end
    local workers = type(b.citizens) == "table" and #b.citizens or 0
    lines[#lines + 1] = ("- %s Lvl %s/%s, %d Arbeiter%s"):format(label(b.name or b.type), tostring(b.level),
      tostring(b.maxLevel), workers, #flags > 0 and (" [" .. table.concat(flags, ", ") .. "]") or "")
  end
  return table.concat(lines, "\n")
end

-- Bauauftraege inkl. der Materialien, die noch fehlen
local function workorders(c)
  local list = call(c, "getWorkOrders") or {}
  if #list == 0 then return "Keine Bauauftraege." end
  local lines = {}
  for _, w in ipairs(list) do
    lines[#lines + 1] = ("Auftrag %s: %s %s -> Lvl %s, %s"):format(tostring(w.id), label(w.workOrderType or w.type),
      label(w.buildingName or "?"), tostring(w.targetLevel or "?"), w.isClaimed and "Builder arbeitet dran" or "kein Builder")
    local missing = {}
    for _, r in ipairs(call(c, "getWorkOrderResources", w.id) or {}) do
      local need = (r.needed or 0) - (r.available or 0) - (r.delivering or 0)
      if need > 0 then missing[#missing + 1] = ("%s x%d"):format(r.displayName or short(label(r.item)), need) end
    end
    lines[#lines + 1] = #missing > 0 and ("  fehlt: " .. table.concat(missing, ", ")) or "  Material komplett"
  end
  return table.concat(lines, "\n")
end

local function research(c)
  local lines = {}
  local function walk(list, depth)
    for _, r in ipairs(list or {}) do
      local status = label(r.status or "?")
      if status:lower():find("progress") or depth == 0 then
        lines[#lines + 1] = ("%s- %s: %s%s"):format(("  "):rep(depth), label(r.name), status,
          type(r.progress) == "number" and (" " .. num(r.progress * 100, 0) .. "%") or "")
      end
      if depth < 6 then walk(r.children, depth + 1) end
    end
  end
  local tree = call(c, "getResearch") or {}
  for branch, list in pairs(tree) do
    lines[#lines + 1] = "Zweig " .. tostring(branch) .. ":"
    walk(type(list) == "table" and (list[1] and list or { list }) or {}, 1)
  end
  return #lines > 0 and table.concat(lines, "\n") or "Keine Forschungsdaten."
end

local function visitors(c)
  local list = call(c, "getVisitors") or {}
  if #list == 0 then return "Keine Besucher in der Taverne." end
  local lines = {}
  for _, v in ipairs(list) do
    local cost = v.recruitCost and (label(v.recruitCost) .. " x" .. tostring(v.recruitCost.count or "?")) or "?"
    lines[#lines + 1] = ("- %s, kostet %s"):format(tostring(v.name), cost)
  end
  return table.concat(lines, "\n")
end

M.TOPICS = {
  overview = overview, requests = requests, citizens = citizens, buildings = buildings,
  workorders = workorders, research = research, visitors = visitors,
}
M.TOPIC_NAMES = { "overview", "requests", "citizens", "buildings", "workorders", "research", "visitors" }

function M.query(topic)
  local c = find()
  if not c then
    return "Kein Colony Integrator erreichbar. Er muss direkt neben der Turtle stehen (am Heimplatz)."
  end
  if call(c, "isInColony") == false then return "Der Colony Integrator steht nicht innerhalb einer Kolonie." end
  local fn = M.TOPICS[topic or "overview"]
  if not fn then return "Unbekanntes Thema: " .. tostring(topic) end
  local ok, res = pcall(fn, c)
  return ok and res or ("Fehler beim Auslesen: " .. tostring(res))
end

return M
