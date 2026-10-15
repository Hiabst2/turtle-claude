-- tests/cc.lua - minimale Nachbildung der ComputerCraft-APIs, damit die Turtle-Programme mit plain Lua laufen.
-- Nur fuer Tests ausserhalb von Minecraft; wird von update nicht heruntergeladen.

local M = {}

-- Dateisystem im Arbeitsspeicher: CC-Pfade ("/.nav") sind Schluessel einer Tabelle. Kein Prozessstart je
-- Dateizugriff (frueher mkdir/rm/ls per Shell, das machte die Tests minutenlang).
local files, dirs = {}, {}
local function norm(p) return (p:gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")) end
local function parent(p) return p:match("^(.*)/[^/]*$") or "" end
local function mkdirs(p)
  while p ~= "" and not dirs[p] do
    dirs[p] = true
    p = parent(p)
  end
end
-- alle Eintraege unterhalb von p (fuer delete und move von Ordnern)
local function below(p)
  local list, prefix = {}, p .. "/"
  for k in pairs(files) do if k:sub(1, #prefix) == prefix then list[#list + 1] = { "f", k } end end
  for k in pairs(dirs) do if k:sub(1, #prefix) == prefix then list[#list + 1] = { "d", k } end end
  return list
end

fs = {
  exists = function(p) p = norm(p) return p == "" or files[p] ~= nil or dirs[p] == true end,
  isDir = function(p) p = norm(p) return p == "" or dirs[p] == true end,
  makeDir = function(p) mkdirs(norm(p)) end,
  list = function(p)
    p = norm(p)
    local names, prefix = {}, p == "" and "" or (p .. "/")
    for _, t in ipairs({ files, dirs }) do
      for k in pairs(t) do
        local rest = k:sub(#prefix + 1)
        if k:sub(1, #prefix) == prefix and rest ~= "" and not rest:find("/", 1, true) then names[#names + 1] = rest end
      end
    end
    table.sort(names)
    return names
  end,
  delete = function(p)
    p = norm(p)
    for _, e in ipairs(below(p)) do if e[1] == "f" then files[e[2]] = nil else dirs[e[2]] = nil end end
    files[p], dirs[p] = nil, nil
  end,
  move = function(a, b)
    a, b = norm(a), norm(b)
    assert(files[a] or dirs[a], "move: " .. a .. " fehlt")
    mkdirs(parent(b))
    if files[a] then
      files[b], files[a] = files[a], nil
    else
      for _, e in ipairs(below(a)) do
        local nk = b .. e[2]:sub(#a + 1)
        if e[1] == "f" then files[nk], files[e[2]] = files[e[2]], nil else dirs[nk], dirs[e[2]] = true, nil end
      end
      dirs[b], dirs[a] = true, nil
    end
  end,
  open = function(p, mode)
    p = norm(p)
    if mode == "w" then
      -- wie in CC: beim Schreiben werden fehlende Ordner angelegt, die Datei ist sofort leer
      mkdirs(parent(p))
      files[p] = ""
      return {
        write = function(s) files[p] = files[p] .. tostring(s) end,
        close = function() end,
      }
    end
    local text = files[p]
    if not text then return nil end
    return { readAll = function() return text end, close = function() end }
  end,
}
function M.writeFile(p, text) p = norm(p) mkdirs(parent(p)) files[p] = text end
function M.readFile(p) return files[norm(p)] end
function M.reset() files, dirs = {}, {} end

-- textutils: serialize ueber Lua-Literale, JSON wird nicht wirklich kodiert, sondern durchgereicht
local function ser(v, indent)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key = type(k) == "string" and ("[%q]"):format(k) or "[" .. tostring(k) .. "]"
      parts[#parts + 1] = key .. "=" .. ser(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(v) == "string" then
    return ("%q"):format(v)
  end
  return tostring(v)
end
M.sent = {} -- alle Request-Bodies an die API, als Lua-Tabellen
M.responses = {} -- vorbereitete API-Antworten, der Reihe nach
textutils = {
  serialize = function(v) return ser(v) end,
  unserialize = function(s)
    local fn = load("return " .. s, "unserialize", "t", {})
    if not fn then return nil end
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
  end,
  -- Kopie, weil der Verlauf danach weiterwaechst (wie beim echten JSON ein Schnappschuss)
  serializeJSON = function(v)
    local function copy(t)
      if type(t) ~= "table" then return t end
      local c = {}
      for k, val in pairs(t) do c[k] = copy(val) end
      return c
    end
    M.sent[#M.sent + 1] = copy(v)
    return "#" .. #M.sent
  end,
  unserializeJSON = function(s) return s end,
}

settings = {
  values = {},
  get = function(k, d) local v = settings.values[k] if v == nil then return d end return v end,
  set = function(k, v) settings.values[k] = v end,
  save = function() end,
}

-- Ereignisse und Koroutinen wie in CC: pullEvent gibt die Kontrolle an parallel zurueck
M.events = {}
os.queueEvent = function(...) M.events[#M.events + 1] = table.pack(...) end
os.pullEvent = function(filter) return coroutine.yield(filter) end
os.getComputerLabel = function() return M.label end
M.timers = 0
os.startTimer = function() M.timers = M.timers + 1 return M.timers end
os.cancelTimer = function() end
os.epoch = function() return 0 end
sleep = function() end

parallel = {
  waitForAny = function(...)
    local cos, filters = {}, {}
    for i, fn in ipairs({ ... }) do
      cos[i] = coroutine.create(fn)
      local ok, f = coroutine.resume(cos[i])
      assert(ok, f)
      filters[i] = f
    end
    while #M.events > 0 do
      local ev = table.remove(M.events, 1)
      for i, co in ipairs(cos) do
        if coroutine.status(co) == "suspended" and (filters[i] == nil or filters[i] == ev[1]) then
          local ok, f = coroutine.resume(co, table.unpack(ev, 1, ev.n))
          assert(ok, f)
          filters[i] = f
        end
      end
    end
  end,
}

-- Dateien fuer http.get, Schluessel "<ref>/<pfad>" (z.B. "main/update.lua", "abc123/nav.lua")
-- oder "api:<branch>" fuer die GitHub-API (Inhalt dann eine Tabelle, unserializeJSON reicht sie durch)
M.web = {}
M.gets = {}
http = {
  get = function(url)
    M.gets[#M.gets + 1] = url
    local key = url:find("api.github.com", 1, true) and ("api:" .. url:match("commits/(.+)$"))
      or url:match("turtle%-claude/([^?]+)")
    local body = M.web[key]
    if not body then return nil, "404 " .. tostring(key) end
    return { readAll = function() return body end, close = function() end }
  end,
  -- Eine Antwort { fail = 529 } simuliert einen HTTP-Fehler, { fail = "timeout" } einen Timeout
  post = function()
    M.posts = (M.posts or 0) + 1
    local resp = table.remove(M.responses, 1)
    assert(resp, "keine vorbereitete API-Antwort mehr")
    if resp.fail == "timeout" then return nil, "Timed out" end
    if resp.fail then
      local code = resp.fail
      return nil, "HTTP " .. code, {
        getResponseCode = function() return code end,
        readAll = function() return "fehler " .. code end,
        close = function() end,
      }
    end
    return { readAll = function() return resp end, close = function() end }
  end,
}

-- shell.run startet ein Programm aus dem simulierten Dateisystem
shell = {
  run = function(prog, ...)
    local file = (fs.exists(prog) and not fs.isDir(prog)) and prog or (prog .. ".lua")
    local fn = assert(load(assert(M.readFile(file), "kein Programm " .. file), "@" .. file))
    return fn(...)
  end,
}
os.setComputerLabel = function(l) M.label = l end
os.getComputerID = function() return 7 end
write = function(s) M.out[#M.out + 1] = s end

colors = setmetatable({}, { __index = function() return 0 end })
term = { setTextColor = function() end, clear = function() end, setCursorPos = function() end }
M.out = {}
print = function(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end M.out[#M.out + 1] = table.concat(t, " ") end
printError = print
read = function() return coroutine.yield("never") end

-- Chat Box: gesendete Nachrichten werden gesammelt
M.chat = {}
M.chatBox = { sendMessage = function(msg) M.chat[#M.chat + 1] = msg return true end }
M.peripherals = {}
peripheral = {
  find = function(t) return M.peripherals[t] end,
  getType = function() return nil end,
  wrap = function() return nil end,
}

-- Turtle: alles klappt, einzelne Funktionen lassen sich in Tests ueberschreiben
turtle = setmetatable({
  getFuelLevel = function() return 1000 end,
  getEquippedLeft = function() return { name = "minecraft:diamond_pickaxe" } end,
  getEquippedRight = function() return nil end,
  getFuelLimit = function() return 20000 end,
  getSelectedSlot = function() return 1 end,
  getItemDetail = function() return nil end,
  getItemCount = function() return 0 end,
  inspect = function() return false end, inspectUp = function() return false end, inspectDown = function() return false end,
  detect = function() return false end, detectUp = function() return false end, detectDown = function() return false end,
}, { __index = function() return function() return true end end })

return M
