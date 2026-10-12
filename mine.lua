-- mine.lua - Stripmine und Tunnel, inkl. Erzadern, Fuel-Check und Ausladen
-- Wird von claude.lua und den Programmen stripmine/tunnel geladen.

local nav = require("nav")
local M = {}

local function must(ok, err)
  if not ok then error(err or "Fehler", 0) end
  return ok
end

local function clamp(v, lo, hi, default)
  v = tonumber(v) or default
  return math.max(lo, math.min(hi, math.floor(v)))
end

local function copy(p) return { x = p.x, y = p.y, z = p.z, f = p.f } end

local function isOre(ok, data)
  if not ok then return false end
  local tags = data.tags or {}
  return tags["c:ores"] or tags["forge:ores"] or data.name:find("_ore$") or data.name:find("ancient_debris")
end

local INSPECT = { front = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local OPPOSITE = { up = "down", down = "up" }

local function found(ctx, name)
  ctx.ores[name] = (ctx.ores[name] or 0) + 1
end

-- Steht in einem gerade abgebauten Erz und baut die ganze Ader rekursiv ab.
local function vein(ctx, depth)
  if depth > 24 then return end
  for _, d in ipairs({ "up", "down" }) do
    local ok, data = INSPECT[d]()
    if isOre(ok, data) then
      found(ctx, data.name)
      must(nav[d](true))
      vein(ctx, depth + 1)
      must(nav[OPPOSITE[d]](true))
    end
  end
  for _ = 1, 4 do
    local ok, data = turtle.inspect()
    if isOre(ok, data) then
      found(ctx, data.name)
      must(nav.forward(true))
      vein(ctx, depth + 1)
      must(nav.back(true))
    end
    nav.turnRight()
  end
end

-- Prueft oben/unten und optional links/rechts auf Erz.
local function scan(ctx, sides)
  for _, d in ipairs({ "up", "down" }) do
    local ok, data = INSPECT[d]()
    if isOre(ok, data) then
      found(ctx, data.name)
      must(nav[d](true))
      vein(ctx, 1)
      must(nav[OPPOSITE[d]](true))
    end
  end
  if not sides then return end
  for i = 1, 2 do
    if i == 1 then nav.turnLeft() else nav.turnAround() end
    local ok, data = turtle.inspect()
    if isOre(ok, data) then
      found(ctx, data.name)
      must(nav.forward(true))
      vein(ctx, 1)
      must(nav.back(true))
    end
  end
  nav.turnLeft()
end

-- Heimweg: erst zurueck zum Startpunkt des Auftrags (durch die eigenen Gaenge), dann heim.
local function tripHome(ctx)
  local s = ctx.start
  must(nav.goTo(s.x, s.y, s.z, ctx.order))
  must(nav.goHome())
end

local function unloadAndReturn(ctx)
  ctx.say("Inventar voll, bringe alles zur Truhe.")
  local back = copy(nav.pos())
  tripHome(ctx)
  must(nav.unload())
  local s = ctx.start
  must(nav.goTo(s.x, s.y, s.z, nav.HOME_ORDER:reverse()))
  must(nav.goTo(back.x, back.y, back.z, ctx.order:reverse()))
  nav.face(back.f)
end

-- Vor jedem Schritt: genug Fuel fuer den Heimweg? Platz im Inventar?
local function maintain(ctx)
  local need = nav.dist(nav.pos(), ctx.start) + nav.dist(ctx.start, nav.home()) + 64
  if nav.fuel() < need then nav.refuel(need + 800) end
  if nav.fuel() < need then
    ctx.say("Fuel wird knapp, fahre heim.")
    tripHome(ctx)
    error("Fuel knapp, bin heimgefahren", 0)
  end
  if nav.freeSlots() < 3 and ctx.junk then nav.dropJunk() end
  if nav.freeSlots() < 3 then unloadAndReturn(ctx) end
end

-- Laufender Auftrag wird in /.job gespeichert. Startet die Turtle neu (z.B. Chunk entladen),
-- kann claude.lua ihn mit M.resume() an der gleichen Stelle fortsetzen.
local JOB_FILE = "/.job"

local function saveJob(kind, opts)
  local f = fs.open(JOB_FILE, "w")
  f.write(textutils.serialize({ kind = kind, opts = opts }))
  f.close()
end

function M.pendingJob()
  if not fs.exists(JOB_FILE) then return nil end
  local f = fs.open(JOB_FILE, "r")
  local job = textutils.unserialize(f.readAll())
  f.close()
  return job
end

function M.clearJob()
  if fs.exists(JOB_FILE) then fs.delete(JOB_FILE) end
end

local function newCtx(say, junk, savedStart)
  local start = savedStart and copy(savedStart) or copy(nav.pos())
  -- Hauptachse = Blickrichtung beim Start; zurueck geht es erst quer, dann laengs
  local main = start.f % 2 == 0 and "z" or "x"
  local perp = main == "z" and "x" or "z"
  return { start = start, order = perp .. main .. "y", ores = {}, say = say or function() end, junk = junk ~= false }
end

local function finish(ctx, goHome)
  local lines = {}
  if goHome then
    tripHome(ctx)
    local ok, info = nav.unload()
    lines[#lines + 1] = ok and ("Ausgeladen: " .. info .. " Items") or ("Nicht ausgeladen: " .. info)
  end
  return lines
end

local function summary(ctx, lines)
  local ores = {}
  for name, n in pairs(ctx.ores) do ores[#ores + 1] = name:gsub("^minecraft:", "") .. " x" .. n end
  table.insert(lines, 1, ("Abgebaut: %d Bloecke. Erzbloecke: %s"):format(nav.stats.blocks,
    #ores > 0 and table.concat(ores, ", ") or "keine"))
  lines[#lines + 1] = "Fuel: " .. tostring(nav.fuel())
  lines[#lines + 1] = nav.where()
  return table.concat(lines, "\n")
end

-- Bei einem fortgesetzten Auftrag erst durch die eigenen Gaenge zurueck zum Startpunkt fahren.
-- Von dort faehrt der Auftrag die erledigten Abschnitte einfach ab.
local function resumeAt(ctx)
  local s, p = ctx.start, nav.pos()
  if p.x == s.x and p.y == s.y and p.z == s.z then return end
  must(nav.goTo(s.x, s.y, s.z, "y" .. ctx.order:sub(1, 2)))
  nav.face(s.f)
end

-- Hauptgang geradeaus, alle `spacing` Bloecke ein Seitengang links und rechts.
-- Gaenge sind 2 hoch, Erze in Boden, Decke und Seitenwaenden werden mitgenommen.
function M.stripmine(opts, say)
  local length = clamp(opts.length, 1, 256, 32)
  local branch = clamp(opts.branch, 0, 64, 8)
  local spacing = clamp(opts.spacing, 2, 16, 3)
  local ctx = newCtx(say, opts.drop_junk, opts.start)
  local fwd = ctx.start.f
  opts.start = ctx.start
  resumeAt(ctx)
  saveJob("stripmine", opts)

  for i = 1, length do
    maintain(ctx)
    nav.face(fwd)
    must(nav.forward(true))
    if i > (opts.skip or 0) then -- erledigte Abschnitte nach einem Neustart nur durchfahren
      scan(ctx, branch == 0)
      must(nav.dig("up"))

      if branch > 0 and i % spacing == 0 then
        for _, turn in ipairs({ nav.turnLeft, nav.turnRight }) do
          nav.face(fwd)
          turn()
          local dir = nav.pos().f
          local walked = 0
          for _ = 1, branch do
            maintain(ctx)
            nav.face(dir)
            must(nav.forward(true))
            walked = walked + 1
            scan(ctx, true)
            must(nav.dig("up"))
          end
          -- zurueck in den Hauptgang
          nav.face((dir + 2) % 4)
          for _ = 1, walked do must(nav.forward(true)) end
        end
        nav.face(fwd)
      end
      opts.skip = i
      saveJob("stripmine", opts)
    end
  end

  return summary(ctx, finish(ctx, opts.home ~= false))
end

-- Tunnel mit Breite x Hoehe. Die Turtle steht unten links, der Tunnel geht nach rechts und oben.
function M.tunnel(opts, say)
  local length = clamp(opts.length, 1, 256, 16)
  local width = clamp(opts.width, 1, 16, 3)
  local height = clamp(opts.height, 1, 16, 3)
  local ctx = newCtx(say, opts.drop_junk, opts.start)
  local fwd = ctx.start.f
  local right, left = (fwd + 1) % 4, (fwd + 3) % 4
  opts.start = ctx.start
  resumeAt(ctx)
  saveJob("tunnel", opts)

  for i = 1, length do
    maintain(ctx)
    nav.face(fwd)
    must(nav.forward(true))
    if i > (opts.skip or 0) then -- erledigte Abschnitte nach einem Neustart nur durchfahren
      local col, goRight = 0, true
      for y = 1, height do
        if width > 1 then
          nav.face(goRight and right or left)
          for _ = 1, width - 1 do
            must(nav.forward(true))
            col = col + (goRight and 1 or -1)
          end
          goRight = not goRight
        end
        if y < height then must(nav.up(true)) end
      end
      if col > 0 then
        nav.face(left)
        for _ = 1, col do must(nav.forward(true)) end
      end
      for _ = 1, height - 1 do must(nav.down(true)) end
      opts.skip = i
      saveJob("tunnel", opts)
    end
  end
  nav.face(fwd)

  return summary(ctx, finish(ctx, opts.home == true))
end

-- Fuehrt einen Auftrag aus und liefert immer einen Text zurueck, auch bei Abbruch.
function M.run(job, opts, say)
  opts = opts or {}
  nav.stats.blocks = 0
  local ok, res = pcall(job, opts, say)
  M.clearJob()
  if ok then return "Fertig. " .. res end

  local msg = "Gestoppt: " .. tostring(res)
  -- bei Zonen- oder anderen Fehlern sicher heimfahren, bei "stop" stehen bleiben
  if res ~= "abgebrochen" and opts.start then
    local back = pcall(tripHome, newCtx(say, true, opts.start))
    msg = msg .. (back and "\nBin heimgefahren." or "\nDer Heimweg hat nicht geklappt.")
  end
  return msg .. "\n" .. nav.where()
end

-- Setzt einen nach einem Neustart unterbrochenen Auftrag fort. Gibt nil zurueck, wenn keiner offen ist.
function M.resume(say)
  local job = M.pendingJob()
  if not job or not M[job.kind] then
    M.clearJob()
    return nil
  end
  return M.run(M[job.kind], job.opts, say), job.kind
end

return M
