-- commander.lua - Command-Node: Claude als Leitstelle auf einem Computer mit Chat Box (P3.3)
--
-- Steuert Turtles nur ueber Auftraege an die Zentrale (job), fragt Flotte (gateway), Karte (map) und
-- Wegkosten (path) ueber TurtleMQ ab. Zonen/Orte aendern braucht das "ja" des Besitzers (agent.lua).
-- Fertige und gescheiterte Auftraege meldet die Leitstelle von selbst im Chat (Abo job.complete/job.fail).

local agent = require("agent")
local version = require("version")
local text = require("text")

local M = {}
M.ASK_TIMEOUT = 8 -- Sekunden, die auf eine Antwort gewartet wird
M.BRIEF_TIMEOUT = 3 -- Sekunden fuer die Lagemeldung am Anfang einer Sitzung (sie soll die Antwort kaum bremsen)

local FACINGS = { sued = 0, west = 1, nord = 2, ost = 3 }
local FACING_NAMES = { [0] = "sued", "west", "nord", "ost" }

local function int(desc) return { type = "integer", description = desc } end
local function str(desc) return { type = "string", description = desc } end
local function obj(props, required) return { type = "object", properties = props or {}, required = required } end

local function fmtPos(p)
  if type(p) ~= "table" then return "?" end
  return ("%s %s %s"):format(tostring(p.x), tostring(p.y), tostring(p.z))
end

function M.system(name)
  return ([[Du bist %s, die Leitstelle fuer Mining-Turtles in Minecraft (ComputerCraft). Spieler reden per Chat mit dir.
- Antworte kurz (1-3 Saetze), locker, auf Deutsch und OHNE Umlaute (ae, oe, ue, ss).
- Du steuerst Turtles nie direkt. Du legst Auftraege bei der Zentrale an (job_create); die Zentrale gibt sie einer
  passenden Turtle (Rolle, Ausruestung, genug Fuel). Fertige oder gescheiterte Auftraege meldest du von selbst.
- Auftragstypen: orehunt (Erzjagd mit Geo Scanner, am besten fuer Erz; rounds, radius, level, layers), stripmine (length, branch,
  spacing), tunnel (length, width, height), stonehunt (Stein sammeln: amount Items, Standard 640; gegraben wird
  6 Bloecke unter der Oberflaeche oder auf level), goto (x, y, z), gohome (zum Lager und heim).
- Was behalten wird: Standard ist Beute (Erze, Rohstoffe, Edelsteine, Kohle), alles andere wirft die Turtle ab.
  keep = zusaetzlich behalten (Teile von Itemnamen, z.B. ["amethyst"]); only = true behaelt NUR keep.
  stonehunt behaelt ohne Angabe nur Bruchstein und Bruch-Deepslate; fuer andere Steine keep angeben
  (z.B. ["minecraft:cobblestone"] oder ["minecraft:dirt"]).
- orehunt: x, z ist nur der Einstieg, gescannt wird auf level (Abbauhoehe, Standard 16). Je nach Erz: Kohle 96,
  Kupfer 48, Eisen/Gold/Redstone 16, Lapis 0, Diamant -54, Redstone tief -58. Fragt keiner, nimm 16 oder schlage
  passend zum gewuenschten Erz vor. layers = Schichten untereinander (je 16 tiefer). level wird auf Zone und
  Hoehenlimit begrenzt.
- Nennt ein Spieler eine Zone ("in mine1"), gib zone an: Bereich und Startpunkt kommen dann aus der Zone. Die Turtle
  muss den Startpunkt erreichen koennen (sie fliegt durch Luft, graebt nur in Zonen); nennt der Spieler einen
  Einstieg/Schacht, nimm dessen Koordinaten als x, y, z.
- Ueberblick: jobs_list (Auftraege), fleet (Turtles), map_show (Zonen, Orte), fuel_estimate.
- Zonen, Hoehenlimit und Orte aenderst du nur mit map_change und nur, wenn der Spieler es ausdruecklich verlangt -
  nie aus eigenem Antrieb. Der Besitzer muss im Chat mit "ja" bestaetigen.
- Spieler koennen jederzeit "stop" schreiben.]]):format(name)
end

function M.new(opts)
  local node = opts.node
  local c = { node = node, labels = {}, colony = opts.colony }

  -- Anfrage ueber TurtleMQ, wartet auf die Antwort mit passendem reply_to
  function c.ask(target, topic, payload, timeout)
    local id = node:send(target, topic, payload or {}, { ttl = 120 })
    node:flush()
    local deadline = node.now() + (timeout or M.ASK_TIMEOUT) * 1000
    local answer
    while answer == nil and node.now() < deadline do
      node:poll(0.5, { quiet = 0.2 })
      node:process(function(m)
        if m.reply_to == id then answer = m.payload else c.onMessage(m) end
      end)
      node:flush()
    end
    return answer
  end

  local function label(id)
    return c.labels[id] or ("#" .. tostring(id))
  end

  -- Meldungen, die nicht Antwort auf eine Frage sind (Abo: job.state - das Urteil der Zentrale, R5)
  function c.onMessage(m)
    local p = type(m.payload) == "table" and m.payload or {}
    local text
    if m.topic ~= "job.state" then return end
    local who = label(p.worker)
    if p.state == "complete" then
      text = ("Auftrag %s fertig (%s): %s"):format(tostring(p.id), who, tostring(p.result or ""))
    elseif p.state == "cancelled" and p.result then
      text = ("Auftrag %s abgebrochen (%s): %s"):format(tostring(p.id), who,
        (tostring(p.result):gsub("^Gestoppt: abgebrochen[^\n]*\n?", "")))
    elseif p.state == "created" and p.retry then
      text = ("Auftrag %s: %s meldet Problem: %s (wird erneut versucht)"):format(tostring(p.id), who,
        tostring(p.reason or "?"))
    elseif p.state == "failed" then
      text = ("Auftrag %s gescheitert (%s): %s"):format(tostring(p.id), who, tostring(p.reason or "?"))
    end
    if text then
      c.agent:reply(text:sub(1, 800), true)
      c.agent.notes[#c.agent.notes + 1] = "[Meldung] " .. text
    end
  end

  local lastBeat
  function c.start()
    node:register({ "command" }, { label = opts.name, role = "command", mode = "online" })
    node:send("gateway", "mq.unsubscribe", { topics = { "job.complete", "job.fail" } }) -- altes Abo (vor R5)
    node:subscribe({ "job.state" })
    node:flush()
  end

  -- im Leerlauf aufrufen: Post annehmen, Meldungen verarbeiten, Lebenszeichen
  function c.tick(timeout)
    local now = node.now()
    if not lastBeat or now - lastBeat > 60000 then
      lastBeat = now
      node:drop(function(m) return m.topic == "worker.heartbeat" end)
      node:send("gateway", "worker.heartbeat", { label = opts.name, role = "command", mode = "online",
        interval = 60, version = version.text() }, { ttl = 300 })
    end
    node:poll(timeout or 0, { quiet = 0.2 })
    node:process(c.onMessage)
    node:flush()
  end

  -- Karte holen (Zonen, Orte) fuer Ortsangaben in Auftraegen
  local function mapData()
    return c.ask("map", "map.get", { rev = 0 })
  end

  local function zoneByName(name)
    local data = mapData()
    if not data then return nil, nil, "Map-Dienst antwortet nicht" end
    for _, z in ipairs(data.zones or {}) do
      if z.name == name then return z, data end
    end
    return nil, data, "keine Zone namens " .. tostring(name)
  end

  local tools = {}

  tools.jobs_list = function(input)
    local r = c.ask("job", "job.list", { all = input.all == true })
    if not r then return "Die Zentrale antwortet nicht." end
    local lines = {}
    for _, j in ipairs(r.jobs or {}) do
      lines[#lines + 1] = ("%s %s: %s%s%s%s"):format(j.id, j.type, j.state,
        j.worker and (", " .. label(j.worker)) or "", j.progress and (", " .. j.progress) or "",
        j.reason and (", Grund: " .. j.reason) or "")
    end
    return #lines > 0 and table.concat(lines, "\n") or "Keine aktuellen Auftraege."
  end

  tools.job_create = function(input)
    local p = { type = input.type, priority = input.priority, params = {} }
    for _, k in ipairs({ "rounds", "radius", "level", "layers", "length", "branch", "spacing", "width", "height",
      "amount", "lanes", "keep", "only" }) do
      if input[k] ~= nil then p.params[k] = input[k] end
    end
    if input.zone then
      local z, data, err = zoneByName(input.zone)
      if not z then return err end
      p.area = { x1 = z.x1, y1 = z.y1, z1 = z.z1, x2 = z.x2, y2 = z.y2, z2 = z.z2 }
      if input.x == nil then
        -- Mitte der Zone, oben (unter dem Hoehenlimit), dort kann die Turtle von oben einsteigen
        input.x = math.floor((z.x1 + z.x2) / 2)
        input.z = math.floor((z.z1 + z.z2) / 2)
        input.y = math.min(math.max(z.y1, z.y2), (data.maxY or 50))
      end
    end
    if input.type == "goto" then
      if input.x == nil then return "goto braucht x, y, z" end
      p.params.x, p.params.y, p.params.z = input.x, input.y, input.z
    elseif input.x ~= nil then
      p.params.start = { x = input.x, y = input.y, z = input.z, f = FACINGS[input.facing or "nord"] or 2 }
    end
    -- R6: kam auf dieselbe Anfrage keine Antwort, mit derselben request_id nochmal - die Zentrale erkennt sie
    local key = text.canonical(p)
    local now = node.now()
    if c.unsure and c.unsure.key == key and now - c.unsure.at < 600 * 1000 then
      p.request_id = c.unsure.rid
    else
      p.request_id = ("%d-%d-%d"):format(os.getComputerID(), now, math.random(1, 999999))
    end
    local r = c.ask("job", "job.create", p)
    if not r then
      c.unsure = { key = key, rid = p.request_id, at = now }
      return "Die Zentrale antwortet nicht, Auftrag vielleicht nicht angelegt. Nochmal job_create mit denselben "
        .. "Angaben ist sicher (kein doppelter Auftrag)."
    end
    c.unsure = nil
    if r.error then return "Nicht angelegt: " .. r.error end
    return ("Auftrag %s angelegt (%s%s). Die Zentrale gibt ihn der naechsten passenden Turtle."):format(r.id, p.type,
      p.params.start and (" ab " .. fmtPos(p.params.start)) or "")
  end

  tools.job_cancel = function(input)
    local r = c.ask("job", "job.cancel", { id = input.id })
    if not r then return "Die Zentrale antwortet nicht." end
    return r.error or (r.id .. " ist jetzt " .. tostring(r.state))
  end

  tools.fleet = function()
    local r = c.ask("gateway", "system.status", {})
    if not r then return "Das Gateway antwortet nicht." end
    local lines = {}
    for _, d in ipairs(r.devices or {}) do
      if d.label then c.labels[d.id] = d.label end
      lines[#lines + 1] = ("%s [%s]: %s, vor %ss%s%s%s"):format(tostring(d.label or ("#" .. tostring(d.id))),
        tostring(d.role), tostring(d.state), tostring(d.seen_s),
        type(d.pos) == "table" and (" bei " .. fmtPos(d.pos)) or "",
        d.fuel and (", Fuel " .. tostring(d.fuel)) or "", d.job and (", " .. tostring(d.job)) or "")
    end
    return #lines > 0 and table.concat(lines, "\n") or "Keine Geraete beim Gateway bekannt."
  end

  tools.map_show = function()
    local data = mapData()
    if not data then return "Der Map-Dienst antwortet nicht." end
    local lines = { ("Hoehenlimit Y %s, Stand %s"):format(tostring(data.maxY), tostring(data.rev)) }
    for _, z in ipairs(data.zones or {}) do
      lines[#lines + 1] = ("Zone %s: x %d..%d, y %d..%d, z %d..%d"):format(z.name, z.x1, z.x2, z.y1, z.y2, z.z1, z.z2)
    end
    local names = {}
    for name in pairs(data.places or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local pl = data.places[name]
      lines[#lines + 1] = ("Ort %s: %s, Blick %s"):format(name, fmtPos(pl), FACING_NAMES[pl.f or 0] or "?")
    end
    return table.concat(lines, "\n")
  end

  tools.map_change = function(input)
    local a = input.action
    local topic, payload, text
    if a == "zone_add" then
      topic, payload = "map.zone.add", { name = input.name, x1 = input.x1, y1 = input.y1, z1 = input.z1,
        x2 = input.x2, y2 = input.y2, z2 = input.z2 }
      text = ("Zone %s anlegen: x %s..%s, y %s..%s, z %s..%s"):format(tostring(input.name), tostring(input.x1),
        tostring(input.x2), tostring(input.y1), tostring(input.y2), tostring(input.z1), tostring(input.z2))
    elseif a == "zone_delete" then
      topic, payload, text = "map.zone.delete", { name = input.name }, "Zone " .. tostring(input.name) .. " loeschen"
    elseif a == "maxy" then
      topic, payload, text = "map.maxy", { maxy = input.maxy }, "Hoehenlimit auf Y " .. tostring(input.maxy) .. " setzen"
    elseif a == "place_set" then
      topic = "map.place.set"
      payload = { name = input.name, x = input.x, y = input.y, z = input.z, f = FACINGS[input.facing or "nord"] or 2 }
      text = ("Ort %s auf %s %s %s, Blick %s setzen"):format(tostring(input.name), tostring(input.x),
        tostring(input.y), tostring(input.z), tostring(input.facing or "nord"))
    elseif a == "place_delete" then
      topic, payload, text = "map.place.delete", { name = input.name }, "Ort " .. tostring(input.name) .. " loeschen"
    else
      return "unbekannte Aktion " .. tostring(a)
    end
    return {
      confirm = text,
      apply = function()
        local r = c.ask("map", topic, payload)
        if not r then return "Der Map-Dienst antwortet nicht, Aenderung unklar (map_show pruefen)." end
        if not r.ok then return "Nicht geaendert: " .. tostring(r.error) end
        return ("Erledigt: %s. Karte Stand %s, die Turtles uebernehmen sie beim naechsten Sync."):format(text, tostring(r.rev))
      end,
    }
  end

  tools.fuel_estimate = function(input)
    local r = c.ask("path", "path.estimate", { from = input.from, to = input.to })
    if not r then return "Der Path-Dienst antwortet nicht." end
    return r.error or ("Etwa " .. tostring(r.fuel) .. " Fuel (Flug ueber Reisehoehe)")
  end

  tools.status = function()
    return ("%s, Version %s, Besitzer %s, Chat Box %s, Colony Integrator %s"):format(opts.name, version.text(),
      tostring(opts.owner), opts.chatBox and "ja" or "nein", c.colony and "ja" or "nein")
  end

  if c.colony then
    tools.colony = function(input) return c.colony.query(input.topic) end
  end

  local pos = function(desc) return obj({ x = int(), y = int(), z = int() }, { "x", "y", "z" }) end
  local defs = {
    { name = "jobs_list", description = "Aktuelle Auftraege der Zentrale mit Zustand, Turtle und Fortschritt.",
      input_schema = obj({ all = { type = "boolean", description = "auch alte, abgeschlossene" } }) },
    { name = "job_create", description = "Legt einen Auftrag bei der Zentrale an. Mit zone kommen Bereich und Startpunkt "
      .. "aus der Zone; sonst x, y, z (Startpunkt) und facing (Blickrichtung beim Start).",
      input_schema = obj({
        type = { type = "string", enum = { "orehunt", "stripmine", "tunnel", "stonehunt", "goto", "gohome" } },
        zone = str("Name einer Mining-Zone"), x = int(), y = int(), z = int(),
        facing = { type = "string", enum = { "nord", "ost", "sued", "west" } },
        priority = int("1-10, Standard 5"), rounds = int("orehunt: Bereiche"), radius = int("orehunt: Scanradius"),
        level = int("orehunt: Abbauhoehe Y, Standard 16"), layers = int("orehunt: Schichten untereinander"),
        length = int(), branch = int("stripmine: Seitengang"), spacing = int("stripmine: Abstand"),
        width = int("tunnel"), height = int("tunnel"),
        amount = int("stonehunt: so viele Items sammeln, Standard 640"), lanes = int("stonehunt: hoechstens Bahnen"),
        keep = { type = "array", items = { type = "string" },
          description = "zusaetzlich behalten (Teile von Itemnamen); bei stonehunt: was gesammelt wird" },
        only = { type = "boolean", description = "nur keep behalten, alles andere abwerfen" },
      }, { "type" }) },
    { name = "job_cancel", description = "Bricht einen Auftrag ab; eine arbeitende Turtle hoert sofort auf.",
      input_schema = obj({ id = str("z.B. J3") }, { "id" }) },
    { name = "fleet", description = "Status aller Turtles und Geraete: Zustand, Position, Fuel, Auftrag.",
      input_schema = obj() },
    { name = "map_show", description = "Zonen, Hoehenlimit und Orte (depot, home:<Turtle>) der Zentrale.",
      input_schema = obj() },
    { name = "map_change", description = "Aendert Zonen, Hoehenlimit oder Orte. Wird erst nach 'ja' des Besitzers "
      .. "ausgefuehrt. place: name 'depot' (Lager) oder 'home:<Turtle>'.",
      input_schema = obj({
        action = { type = "string", enum = { "zone_add", "zone_delete", "maxy", "place_set", "place_delete" } },
        name = str(), x1 = int(), y1 = int(), z1 = int(), x2 = int(), y2 = int(), z2 = int(), maxy = int(),
        x = int(), y = int(), z = int(), facing = { type = "string", enum = { "nord", "ost", "sued", "west" } },
      }, { "action" }) },
    { name = "fuel_estimate", description = "Schaetzt das Fuel fuer einen Flug von A nach B.",
      input_schema = obj({ from = pos(), to = pos() }, { "from", "to" }) },
    { name = "status", description = "Eigener Status der Leitstelle.", input_schema = obj() },
  }
  if c.colony then
    defs[#defs + 1] = { name = "colony", description = "Liest die MineColonies-Kolonie (overview, requests, citizens, "
      .. "buildings, workorders, research, visitors).",
      input_schema = obj({ topic = { type = "string", enum = { "overview", "requests", "citizens", "buildings",
        "workorders", "research", "visitors" } } }, { "topic" }) }
  end

  local READ_ONLY = { jobs_list = true, fleet = true, map_show = true, fuel_estimate = true, status = true, colony = true }

  -- Lagemeldung fuer den Anfang einer Sitzung: laufende Auftraege, im Code zusammengebaut (kein Claude-Aufruf)
  local function brief()
    local r = c.ask("job", "job.list", {}, M.BRIEF_TIMEOUT)
    if not r then return "Stand der Auftraege unbekannt (Zentrale antwortet nicht)." end
    local lines = {}
    for _, j in ipairs(r.jobs or {}) do
      if j.state ~= "complete" and j.state ~= "failed" and j.state ~= "cancelled" then
        lines[#lines + 1] = ("%s %s: %s%s"):format(j.id, j.type, j.state, j.worker and (", " .. label(j.worker)) or "")
      end
    end
    if #lines == 0 then return "Keine offenen Auftraege." end
    return "Offene Auftraege: " .. table.concat(lines, "; ")
  end

  c.agent = agent.new({
    name = opts.name, owner = opts.owner, key = opts.key, model = opts.model, effort = opts.effort,
    chatBox = opts.chatBox, brief = brief, now = opts.now,
    system = M.system(opts.name), tools = defs, debug = opts.debug,
    readOnly = function(name) return READ_ONLY[name] == true end,
    runTool = function(name, input)
      local fn = tools[name]
      if not fn then return "unbekanntes Tool: " .. tostring(name) end
      return fn(input)
    end,
  })
  c.tools = tools
  return c
end

return M
