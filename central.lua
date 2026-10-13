-- central: Zentrale mit Job-Dienst (spaeter auch map, path). Computer mit Wireless/Ender Modem in einem
-- dauerhaft geladenen Chunk. Oben Status, unten eine Eingabezeile fuer Auftraege:
--   add orehunt x=725 y=40 z=630 f=nord rounds=2 area=700,0,600,750,60,650 prio=5
--   add stripmine x=.. y=.. z=.. f=ost length=40 branch=8
--   add tunnel x=.. y=.. z=.. f=sued length=20 width=3 height=3
--   add goto x=.. y=.. z=..      add gohome
--   list        cancel J3        help
local mq = require("mq")
local services = require("services")
local jobsvc = require("jobsvc")

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then printError("Kein Wireless/Ender Modem angeschlossen.") return end

local node = mq.new({ link = mq.modemLink(modem) })
local host = services.new(node, { label = os.getComputerLabel() or "Zentrale" })
local jobs = jobsvc.new(host)
host.add("job", jobs)
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
  top.setTextColor(colors.white)
  for _, line in ipairs(jobs:statusLines()) do
    if y > h - 6 then break end
    top.setCursorPos(1, y) top.write(line:sub(1, w)) y = y + 1
  end
  top.setTextColor(colors.gray)
  y = math.max(y, h - 6)
  for i = 1, math.min(#jobs.log, h - 2 - y) do
    top.setCursorPos(1, y) top.write(jobs.log[i]:sub(1, w)) y = y + 1
  end
  top.setTextColor(colors.lightBlue)
  top.setCursorPos(1, h - 2) top.write(message:sub(1, w))
end

local FACING = { sued = 0, west = 1, nord = 2, ost = 3 }

-- "add orehunt x=1 y=2 z=3 f=nord rounds=2 area=..." -> job.create-Payload
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
  elseif cmd == "list" then
    return #jobs:statusLines() .. " aktuelle Auftraege (siehe oben)"
  else
    return "add <orehunt|stripmine|tunnel|goto|gohome> x= y= z= f= ... | list | cancel J1"
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
