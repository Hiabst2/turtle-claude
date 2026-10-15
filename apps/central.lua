-- central: Zentrale mit Job-, Map- und Path-Dienst. Computer mit Wireless/Ender Modem in einem
-- dauerhaft geladenen Chunk. Oben Status, unten eine Eingabezeile fuer Auftraege:
--   add orehunt x=725 y=40 z=630 f=nord rounds=2 area=700,0,600,750,60,650 prio=5
--   add stripmine x=.. y=.. z=.. f=ost length=40 branch=8
--   add tunnel x=.. y=.. z=.. f=sued length=20 width=3 height=3
--   add goto x=.. y=.. z=..      add gohome
--   list        cancel J3        help
--   zone add mine1 700 0 600 750 60 650     zone del mine1     zone maxy 50     zone list
--   place depot 740 64 615 nord             place home Miner1 730 70 640 ost   place del depot
local mq = require("mq")
local services = require("services")
local jobsvc = require("jobsvc")
local mapsvc = require("mapsvc")
local pathsvc = require("pathsvc")

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then printError("Kein Wireless/Ender Modem angeschlossen.") return end

local node = mq.new({ link = mq.modemLink(modem) })
local host = services.new(node, { label = os.getComputerLabel() or "Zentrale" })
local jobs = jobsvc.new(host)
host.add("job", jobs)
local map = mapsvc.new(host)
host.add("map", map)
host.add("path", pathsvc.new(host))
host.heartbeat(true)

local w, h = term.getSize()
local screen = term.current()
local top = window.create(screen, 1, 1, w, h - 2)
local bottom = window.create(screen, 1, h - 1, w, 2)
local message = "Befehle: add, list, cancel, help"

local function draw()
  top.clear()
  top.setCursorPos(1, 1)
  top.setTextColor(colors.yellow)
  top.write(("Zentrale #%d  Outbox %d  Jobs"):format(node.id, node:pending()))
  local y = 2
  top.setTextColor(colors.lightGray)
  for _, line in ipairs(map:statusLines()) do
    top.setCursorPos(1, y) top.write(line:sub(1, w)) y = y + 1
  end
  top.setTextColor(colors.white)
  for _, line in ipairs(jobs:statusLines()) do
    if y > h - 6 then break end
    top.setCursorPos(1, y) top.write(line:sub(1, w)) y = y + 1
  end
  -- Antwort auf den letzten Befehl, umgebrochen; darf bei Bedarf ueber das Protokoll reichen
  local msg = {}
  for part in (message .. "\n"):gmatch("(.-)\n") do
    repeat
      msg[#msg + 1] = part:sub(1, w)
      part = part:sub(w + 1)
    until part == ""
  end
  local first = math.max(2, h - 1 - #msg)
  top.setTextColor(colors.gray)
  y = math.max(y, h - 6)
  local log = {}
  for _, l in ipairs(jobs.log) do log[#log + 1] = l end
  for _, l in ipairs(map.log) do log[#log + 1] = l end
  for i = 1, math.min(#log, first - y) do
    top.setCursorPos(1, y) top.write(log[i]:sub(1, w)) y = y + 1
  end
  top.setTextColor(colors.lightBlue)
  for i = 1, math.min(#msg, h - 2 - first + 1) do
    top.setCursorPos(1, first + i - 1) top.clearLine() top.write(msg[i])
  end
end

local FACING = { sued = 0, west = 1, nord = 2, ost = 3 }

-- "add orehunt x=1 y=2 z=3 f=nord rounds=2 level=16 layers=2 area=..." -> job.create-Payload
-- (orehunt: x/z = Einstieg, level = Abbauhoehe, Standard 16)
local function parseAdd(words)
  local p = { type = words[2], params = {} }
  local start = {}
  for i = 3, #words do
    local k, v = words[i]:match("^(%w+)=(.+)$")
    if not k then return nil, "Format: schluessel=wert (" .. words[i] .. ")" end
    if k == "x" or k == "y" or k == "z" then start[k] = tonumber(v)
    elseif k == "f" then start.f = FACING[v] or tonumber(v)
    elseif k == "prio" then p.priority = tonumber(v)
    elseif k == "area" then
      local n = {}
      for num in v:gmatch("-?%d+") do n[#n + 1] = tonumber(num) end
      if #n ~= 6 then return nil, "area braucht 6 Zahlen" end
      p.area = { x1 = n[1], y1 = n[2], z1 = n[3], x2 = n[4], y2 = n[5], z2 = n[6] }
    else p.params[k] = tonumber(v) or v end
  end
  if start.x and start.y and start.z then
    if p.type == "goto" then
      p.params.x, p.params.y, p.params.z = start.x, start.y, start.z
    else
      p.params.start = { x = start.x, y = start.y, z = start.z, f = start.f or 0 }
    end
  end
  return p
end

local function command(line)
  local words = {}
  for word in line:gmatch("%S+") do words[#words + 1] = word end
  local cmd = words[1]
  if cmd == "add" then
    local p, err = parseAdd(words)
    if not p then return err end
    local job, cerr = jobs:create(p, node.id)
    return job and (job.id .. " angelegt") or cerr
  elseif cmd == "cancel" and words[2] then
    local r = jobs:cancel(words[2])
    return r.error or (r.id .. ": " .. r.state)
  elseif cmd == "show" and words[2] then
    local j = jobs.state.jobs[words[2]] or jobs.state.jobs[words[2]:upper()]
    if not j then return "kein Auftrag " .. words[2] end
    local function pt(p) return p and ("%s %s %s"):format(p.x, p.y, p.z) or "-" end
    local out = { ("%s %s %s, Worker %s, Versuche %s"):format(j.id, j.type, j.state, tostring(j.worker),
      tostring(j.attempts)) }
    local params = {}
    for k, v in pairs(j.params or {}) do
      if k ~= "start" then params[#params + 1] = k .. "=" .. tostring(v) end
    end
    table.sort(params)
    out[#out + 1] = "Start " .. pt(j.params and j.params.start) .. "  " .. table.concat(params, " ")
    if j.area then
      local a = j.area
      out[#out + 1] = ("Bereich %s %s %s bis %s %s %s"):format(a.x1, a.y1, a.z1, a.x2, a.y2, a.z2)
    end
    if j.result then out[#out + 1] = "Ergebnis: " .. j.result end
    if j.reason then out[#out + 1] = "Grund: " .. j.reason end
    return table.concat(out, "\n")
  elseif cmd == "list" then
    return #jobs:statusLines() .. " aktuelle Auftraege (siehe oben)"
  elseif cmd == "zone" then
    local sub = words[2]
    local ok, err
    if sub == "add" then ok, err = map:addZone(words[3], words[4], words[5], words[6], words[7], words[8], words[9])
    elseif sub == "del" then ok, err = map:deleteZone(words[3])
    elseif sub == "maxy" then ok, err = map:setMaxY(words[3])
    else
      local names = {}
      for _, z in ipairs(map.state.zones) do
        names[#names + 1] = ("%s %s %s %s bis %s %s %s"):format(z.name, z.x1, z.y1, z.z1, z.x2, z.y2, z.z2)
      end
      return "Zonen: " .. (#names > 0 and table.concat(names, ", ") or "keine") .. ", Hoehenlimit Y " .. map.state.maxY
    end
    return ok and ("Karte Stand " .. map.state.rev .. ", die Turtles uebernehmen sie beim naechsten Sync") or err
  elseif cmd == "place" then
    local sub = words[2]
    local ok, err
    if sub == "del" then ok, err = map:deletePlace(words[3])
    elseif sub == "list" or sub == nil then
      local names = {}
      for name in pairs(map.state.places) do names[#names + 1] = name end
      table.sort(names)
      if #names == 0 then return "keine Orte. place depot x y z richtung | place home <Turtle> x y z richtung" end
      local out = {}
      for _, name in ipairs(names) do
        local p = map.state.places[name]
        out[#out + 1] = ("%s %d %d %d f%d"):format(name, p.x, p.y, p.z, p.f or 0)
      end
      return table.concat(out, " | ")
    elseif sub == "home" then ok, err = map:setPlace("home:" .. tostring(words[3]), words[4], words[5], words[6], FACING[words[7]] or words[7])
    else ok, err = map:setPlace(sub, words[3], words[4], words[5], FACING[words[6]] or words[6]) end
    return ok and ("Karte Stand " .. map.state.rev) or err
  else
    return "add ... | list | show J1 | cancel J1 | zone add/del/maxy/list | place list/depot/home/del"
  end
end

local function serviceLoop()
  while true do
    host.step(1)
    draw()
  end
end

local function consoleLoop()
  while true do
    bottom.clear()
    bottom.setCursorPos(1, 1)
    bottom.setTextColor(colors.white)
    bottom.write("> ")
    local old = term.redirect(bottom)
    local line = read()
    term.redirect(old)
    local ok, res = pcall(command, line or "")
    message = ok and tostring(res) or ("Fehler: " .. tostring(res))
    draw()
  end
end

draw()
parallel.waitForAny(serviceLoop, consoleLoop)
