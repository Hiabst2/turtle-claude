-- mine.lua - Stripmine und Tunnel, inkl. Erzadern, Fuel-Check und Ausladen
-- Wird von claude.lua und den Programmen stripmine/tunnel geladen.

local nav = require("nav")
local zones = require("zones")
local gear = require("gear")
local path = require("path")
local store = require("store")
local sync = require("sync")
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

local function oreName(name, tags)
  if name:find("_ore$") or name:find("ancient_debris") then return true end
  for k, v in pairs(tags or {}) do
    local tag = type(k) == "string" and k or v -- inspect liefert {tag=true}, der Geo Scanner eine Liste
    if tag == "c:ores" or tag == "forge:ores" or tag == "minecraft:ores" then return true end
  end
  return false
end

local function isOre(ok, data)
  return ok and oreName(data.name, data.tags)
end

-- Erz nur mitnehmen, wenn es in einer Zone liegt (sonst wuerde der Auftrag an der Zonengrenze abbrechen)
local function mayDig(dir, data)
  return zones.check(nav.target(dir), data.name, nav.hasGps())
end

-- An der Zonengrenze nicht abbrechen, sondern nur diesen Gang beenden
local function blocked(err)
  return type(err) == "string" and err:find("Darf hier nicht graben", 1, true) ~= nil
end

local function step(ok, err)
  if ok then return true end
  if blocked(err) then return false end
  error(err or "Fehler", 0)
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
    if isOre(ok, data) and mayDig(d, data) then
      found(ctx, data.name)
      must(nav[d](true))
      vein(ctx, depth + 1)
      must(nav[OPPOSITE[d]](true))
    end
  end
  for _ = 1, 4 do
    local ok, data = turtle.inspect()
    if isOre(ok, data) and mayDig("front", data) then
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
    if isOre(ok, data) and mayDig(d, data) then
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
    if isOre(ok, data) and mayDig("front", data) then
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
  if not ctx.surfaced then must(nav.goTo(s.x, s.y, s.z, ctx.order)) end
  must(nav.goHome())
end

-- Zum Lagerplatz: erst zurueck zum Startpunkt des Auftrags, dann rueber
local function toPoint(ctx, p, order)
  if ctx.map then return path.go(ctx.map, p) end
  return nav.goTo(p.x, p.y, p.z, order)
end

local function tripDepot(ctx)
  local s = ctx.start
  if not ctx.surfaced then must(toPoint(ctx, s, ctx.order)) end -- schon oben (Kiste an der Oberflaeche geholt)
  must(nav.goDepot())
end

local function unloadAndReturn(ctx)
  local back = copy(nav.pos())
  tripDepot(ctx)
  must(nav.unload())
  local s = ctx.start
  must(nav.travel(s.x, s.y, s.z, nav.HOME_ORDER:reverse()))
  must(toPoint(ctx, back, ctx.order:reverse()))
  nav.face(back.f)
end

-- Vor jedem Schritt: genug Fuel fuer den Heimweg? Platz im Inventar? Und ggf. TurtleMQ-Sync.
local function maintain(ctx)
  -- sicherer Punkt zwischen zwei Schritten; ein Fehler beim Funken darf das Minen nie stoppen
  pcall(sync.maybe)
  -- zurueck zum Startpunkt durch die Gaenge, dann so, wie travel() fliegt (hoch auf Reisehoehe und runter)
  local need = nav.dist(nav.pos(), ctx.start) + nav.tripCost(ctx.start, nav.depot()) + 64
  if nav.fuel() < need then nav.refuel(need + 800) end
  if nav.fuel() < need then
    -- daheim wird ausgeladen und Kohle aus dem Lager nachgetankt, dann geht es weiter
    ctx.say("Fuel wird knapp, hole Kohle.")
    unloadAndReturn(ctx)
    if nav.fuel() < need then error("Fuel knapp und daheim keine Kohle gefunden", 0) end
  end
  if nav.freeSlots() < 3 and ctx.junk then nav.dropJunk() end
  if nav.freeSlots() < 3 then
    ctx.say("Inventar voll, bringe alles ins Lager.")
    unloadAndReturn(ctx)
  end
end

-- Laufender Auftrag wird in /.job gespeichert. Startet die Turtle neu (z.B. Chunk entladen),
-- kann claude.lua ihn mit M.resume() an der gleichen Stelle fortsetzen.
local JOB_FILE = "/.job"

local function saveJob(kind, opts)
  store.save(JOB_FILE, { kind = kind, opts = opts })
end

function M.pendingJob()
  return (store.load(JOB_FILE))
end

function M.clearJob()
  for _, suffix in ipairs({ "", ".bak", ".tmp" }) do
    if fs.exists(JOB_FILE .. suffix) then fs.delete(JOB_FILE .. suffix) end
  end
end

local function newCtx(say, junk, savedStart)
  local start = savedStart and copy(savedStart) or copy(nav.pos())
  -- Hauptachse = Blickrichtung beim Start; zurueck geht es erst quer, dann laengs
  local main = start.f % 2 == 0 and "z" or "x"
  local perp = main == "z" and "x" or "z"
  return { start = start, order = perp .. main .. "y", ores = {}, say = say or function() end, junk = junk ~= false }
end

-- Ausruestung, die beim Minen nicht gebraucht wird, in die Zwischenkiste legen (drop = turtle.drop/dropDown)
local function stash(opts, keep, drop)
  local sel = turtle.getSelectedSlot()
  local stashed = 0
  for s = 1, 16 do
    local item = turtle.getItemDetail(s)
    if item and gear.isGear(item.name) and not item.name:find("pickaxe", 1, true)
      and not item.name:find("chat_box", 1, true) and not (keep and item.name:find(keep, 1, true))
      and not (sync.enabled() and item.name:find("modem", 1, true)) then
      turtle.select(s)
      if drop() then stashed = stashed + 1 end
    end
  end
  turtle.select(sel)
  opts.stashed = stashed
  return stashed
end

-- Zwischenkiste an der Oberflaeche NEBEN den Einstieg stellen (die Turtle steht ueber dem Schacht).
-- Nur auf einen freien Platz, gegraben wird dafuer nicht. Liefert true oder false, Grund.
function M.placeChestBeside(opts, say, keep)
  local slot = gear.findSlot("minecraft:chest")
  if not slot then return false, "keine Kiste dabei" end
  local p = nav.pos()
  local f0 = p.f
  local sel = turtle.getSelectedSlot()
  for i = 0, 3 do
    nav.face((f0 + i) % 4)
    if not turtle.detect() then
      turtle.select(slot)
      if turtle.place() then
        turtle.select(sel)
        local t = nav.target("front")
        opts.chest = { x = t.x, y = t.y, z = t.z, f = nav.pos().f, stand = { x = p.x, y = p.y, z = p.z } }
        local n = stash(opts, keep, turtle.drop)
        if say then say(("Zwischenkiste an der Oberflaeche abgestellt (%d %d %d), %d Teile abgelegt."):format(
          t.x, t.y, t.z, n)) end
        return true
      end
      turtle.select(sel)
    end
  end
  nav.face(f0)
  return false, "ringsum kein freier Platz"
end

-- Zwischenkiste: liegt eine Kiste im Inventar, stellt die Turtle sie beim Start unter sich ab und legt dort
-- die Ausruestung ab, die sie beim Minen nicht braucht. Die Kiste ist eine Truhe und damit geschuetzt,
-- waehrend des Auftrags wird sie also nicht angefasst. Am Ende holt die Turtle alles raus und baut sie ab.
-- Worker stellen sie vorher schon an der Oberflaeche ab (placeChestBeside), dann steht sie hier schon.
local function placeChest(ctx, opts, kind, keep)
  if opts.chest then return end -- steht schon (an der Oberflaeche oder Auftrag wird fortgesetzt)
  local slot = gear.findSlot("minecraft:chest")
  if not slot then
    if opts.keep_gear then error("keine Zwischenkiste dabei (ist Pflicht)", 0) end
    return
  end
  if turtle.detectDown() then
    local ok, why = nav.dig("down")
    if not ok then
      if opts.keep_gear then error("kein Platz fuer die Zwischenkiste: " .. tostring(why), 0) end
      ctx.say("Kein Platz fuer die Zwischenkiste, mache ohne weiter.")
      return
    end
  end
  local sel = turtle.getSelectedSlot()
  turtle.select(slot)
  local placed, why = turtle.placeDown()
  turtle.select(sel)
  if not placed then
    if opts.keep_gear then error("Zwischenkiste laesst sich nicht abstellen: " .. tostring(why), 0) end
    ctx.say("Zwischenkiste laesst sich nicht abstellen, mache ohne weiter.")
    return
  end
  local p = nav.pos()
  opts.chest = { x = p.x, y = p.y - 1, z = p.z }
  local stashed = stash(opts, keep, turtle.dropDown)
  saveJob(kind, opts)
  ctx.say(("Zwischenkiste abgestellt, %d Teile abgelegt."):format(stashed))
end

local function retrieveChest(ctx, opts)
  local c = opts.chest
  if not c then return end
  local need = (opts.stashed or 0) + 2
  if nav.freeSlots() < need and ctx.junk then nav.dropJunk() end
  if nav.freeSlots() < need then unloadAndReturn(ctx) end
  local suck, dig, inspect = turtle.suckDown, turtle.digDown, turtle.inspectDown
  if c.stand then
    -- an der Oberflaeche: zurueck zum Einstieg, den Schacht hoch, Kiste steht daneben
    must(toPoint(ctx, ctx.start, ctx.order))
    must(nav.goTo(c.stand.x, c.stand.y, c.stand.z, "yxz"))
    nav.face(c.f)
    suck, dig, inspect = turtle.suck, turtle.dig, turtle.inspect
    ctx.surfaced = true
  else
    must(toPoint(ctx, { x = c.x, y = c.y + 1, z = c.z }, ctx.order))
  end
  local ok, data = inspect()
  if ok and data.name:find("chest", 1, true) then
    while suck() do end
    dig() -- die eigene Kiste darf sie abbauen, darum direkt und nicht ueber nav.dig
  end
  opts.chest = nil
  ctx.say("Zwischenkiste wieder eingepackt.")
end

local function finish(ctx, opts, goHome)
  local lines = {}
  retrieveChest(ctx, opts)
  if goHome then
    tripDepot(ctx)
    local ok, info = nav.unload()
    must(nav.goHome())
    lines[#lines + 1] = ok and ("Ausgeladen: " .. info .. " Items") or ("Nicht ausgeladen: " .. info)
    -- Kiste und Ausruestung zurueck in die Toolbox unter dem Heimplatz - nicht bei Workern (keep_gear):
    -- ohne Modem koennten sie nicht mehr funken und bekaemen nie wieder einen Auftrag
    if not opts.keep_gear then
      local stored = gear.store()
      if stored then lines[#lines + 1] = "Ausruestung und Kiste in die Toolbox gelegt." end
    end
  end
  return lines
end

local function summary(ctx, lines)
  local ores = {}
  for name, n in pairs(ctx.ores) do ores[#ores + 1] = name:gsub("^minecraft:", "") .. " x" .. n end
  local oreCount = 0
  for _, n in pairs(ctx.ores) do oreCount = oreCount + n end
  table.insert(lines, 1, ("Abgebaut: %d Bloecke, davon %d Erz und %d Stein/Sonstiges. Erze: %s"):format(
    nav.stats.blocks, oreCount, math.max(0, nav.stats.blocks - oreCount),
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
  placeChest(ctx, opts, "stripmine")

  for i = 1, length do
    sync.setJob(("stripmine %d/%d"):format(i, length))
    maintain(ctx)
    nav.face(fwd)
    if not step(nav.forward(true)) then
      ctx.say("Ende der Mining-Zone erreicht.")
      break
    end
    if i > (opts.skip or 0) then -- erledigte Abschnitte nach einem Neustart nur durchfahren
      scan(ctx, branch == 0)
      step(nav.dig("up"))

      if branch > 0 and i % spacing == 0 then
        for _, turn in ipairs({ nav.turnLeft, nav.turnRight }) do
          nav.face(fwd)
          turn()
          local dir = nav.pos().f
          local walked = 0
          for _ = 1, branch do
            maintain(ctx)
            nav.face(dir)
            if not step(nav.forward(true)) then break end
            walked = walked + 1
            scan(ctx, true)
            step(nav.dig("up"))
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

  return summary(ctx, finish(ctx, opts, opts.home ~= false))
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
  placeChest(ctx, opts, "tunnel")

  for i = 1, length do
    sync.setJob(("tunnel %d/%d"):format(i, length))
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

  return summary(ctx, finish(ctx, opts, opts.home == true))
end

-- Erzjagd mit dem Geo Scanner: scannt die Umgebung und holt sich die Erze ueber die Wege, die am wenigsten
-- Stein kosten. Hoehlen und eigene Gaenge werden bevorzugt (siehe path.lua). Danach ein Stueck weiter.
local function scanArea(map, radius)
  local blocks, err = gear.with("geo_scanner", function(g)
    local res, e = g.scan(radius)
    if not res then
      sleep(3) -- Scanner hat eine Abklingzeit
      res, e = g.scan(radius)
    end
    if not res then error(e or "Scan fehlgeschlagen", 0) end
    return res
  end)
  if not blocks then error("Geo Scanner: " .. tostring(err), 0) end

  -- Koordinaten koennen relativ oder absolut kommen: liegen alle im Scanradius, sind sie relativ
  local relative = true
  for _, b in ipairs(blocks) do
    if math.abs(b.x) > radius + 1 or math.abs(b.y) > radius + 1 or math.abs(b.z) > radius + 1 then
      relative = false
      break
    end
  end
  local p, list = nav.pos(), {}
  for _, b in ipairs(blocks) do
    local x, y, z = b.x, b.y, b.z
    if relative then x, y, z = p.x + x, p.y + y, p.z + z end
    list[#list + 1] = { x = x, y = y, z = z, name = b.name, tags = b.tags }
  end
  local before = 0
  for _ in pairs(map.ores) do before = before + 1 end
  path.addScan(map, p, radius, list, function(b) return oreName(b.name, b.tags) end)
  local after = 0
  for _ in pairs(map.ores) do after = after + 1 end
  return after - before
end

function M.orehunt(opts, say)
  local rounds = clamp(opts.rounds, 1, 16, 4)
  local radius = clamp(opts.radius, 2, 16, 8)
  local layers = clamp(opts.layers, 1, 8, 1) -- Schichten untereinander, je 2 x radius tiefer
  local ctx = newCtx(say, opts.drop_junk, opts.start)
  local fwd = ctx.start.f
  opts.start = ctx.start
  if not gear.findSlot("geo_scanner") then error("kein Geo Scanner dabei, erst Ausruestung holen", 0) end
  resumeAt(ctx)
  saveJob("orehunt", opts)
  placeChest(ctx, opts, "orehunt", "geo_scanner")

  local map = path.newMap()
  ctx.map = map
  path.markAir(map, nav.pos())
  local function onOre(name) found(ctx, name) end

  -- Scan-Punkte liegen auf einem Raster mit 2 x radius Abstand, damit sich die Scans nicht ueberschneiden.
  -- Als naechstes kommt immer der ungescannte Punkt in der Zone, der am naechsten liegt.
  -- scanned: fertig abgebaut (erst danach eingetragen, sonst ginge ein Bereich nach einem Neustart verloren)
  -- unreachable: kein erlaubter Weg dorthin; zaehlt nicht als erledigt
  opts.scanned = opts.scanned or {}
  opts.unreachable = opts.unreachable or {}
  local spacing = 2 * radius
  local function nextCenter()
    local p, best, bestD = nav.pos(), nil, nil
    for l = 0, layers - 1 do
      for i = -rounds, rounds do
        for j = -rounds, rounds do
          local c = { x = ctx.start.x + i * spacing, y = ctx.start.y - l * spacing, z = ctx.start.z + j * spacing }
          local k = path.key(c.x, c.y, c.z)
          if not opts.scanned[k] and not opts.unreachable[k] and zones.check(c, nil, nav.hasGps()) then
            -- naeher an der Turtle zuerst, bei Gleichstand naeher am Start
            local d = nav.dist(p, c) * 1000 + nav.dist(ctx.start, c)
            if not bestD or d < bestD then best, bestD = c, d end
          end
        end
      end
    end
    return best
  end

  local done = 0
  for _ in pairs(opts.scanned) do done = done + 1 end
  while done < rounds do
    local center = nextCenter()
    if not center then
      ctx.say("Keine ungescannten Bereiche mehr in der Mining-Zone.")
      break
    end
    local k = path.key(center.x, center.y, center.z)
    sync.setJob(("orehunt %d/%d"):format(done + 1, rounds))
    maintain(ctx)
    if step(path.go(map, center, onOre)) then
      local n = scanArea(map, radius)
      ctx.say(("Scan %d/%d: %d neue Erzbloecke."):format(done + 1, rounds, n))
      repeat
        maintain(ctx)
      until not path.nextOre(map, onOre, center, radius)
      opts.scanned[k] = true
      done = done + 1
    else
      opts.unreachable[k] = true
    end
    saveJob("orehunt", opts)
  end

  return summary(ctx, finish(ctx, opts, opts.home ~= false))
end

-- Fuehrt einen Auftrag aus und liefert immer einen Text zurueck, auch bei Abbruch.
function M.run(job, opts, say)
  opts = opts or {}
  nav.stats.blocks = 0
  local ok, res = pcall(job, opts, say)
  M.clearJob()
  sync.setJob(nil)
  if ok then
    pcall(sync.run) -- Auftragsende melden
    return "Fertig. " .. res
  end

  local msg = "Gestoppt: " .. tostring(res)
  -- bei Zonen- oder anderen Fehlern sicher heimfahren, bei "stop" stehen bleiben
  if res ~= "abgebrochen" and opts.start then
    local ctx = newCtx(say, true, opts.start)
    pcall(retrieveChest, ctx, opts)
    local back = pcall(tripHome, ctx)
    msg = msg .. (back and "\nBin heimgefahren." or "\nDer Heimweg hat nicht geklappt.")
  end
  pcall(sync.run) -- Fehler/Abbruch melden
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
