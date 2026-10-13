-- tests/cc.lua - minimale Nachbildung der ComputerCraft-APIs, damit die Turtle-Programme mit plain Lua laufen.
-- Nur fuer Tests ausserhalb von Minecraft; wird von update nicht heruntergeladen.

local M = {}

-- Dateisystem: CC-Pfade ("/.nav") landen in einem Temp-Verzeichnis
local root = os.getenv("CC_ROOT") or "/tmp/cc-test"
os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
local function real(path) return root .. "/" .. path:gsub("^/", "") end

fs = {
  exists = function(p) local f = io.open(real(p), "r") if f then f:close() return true end return false end,
  isDir = function() return false end,
  delete = function(p) os.remove(real(p)) end,
  move = function(a, b) assert(os.rename(real(a), real(b))) end,
  open = function(p, mode)
    local f = io.open(real(p), mode == "w" and "w" or "r")
    if not f then return nil end
    return {
      readAll = function() return f:read("*a") end,
      write = function(s) f:write(s) end,
      close = function() f:close() end,
    }
  end,
}
function M.writeFile(p, text) local f = io.open(real(p), "w") f:write(text) f:close() end
function M.readFile(p) local f = io.open(real(p), "r") if not f then return nil end local t = f:read("*a") f:close() return t end
function M.reset() os.execute("rm -rf " .. root .. " && mkdir -p " .. root) end

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

http = {
  post = function()
    local resp = table.remove(M.responses, 1)
    assert(resp, "keine vorbereitete API-Antwort mehr")
    return { readAll = function() return resp end, close = function() end }
  end,
}

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
  getFuelLimit = function() return 20000 end,
  getSelectedSlot = function() return 1 end,
  getItemDetail = function() return nil end,
  getItemCount = function() return 0 end,
  inspect = function() return false end, inspectUp = function() return false end, inspectDown = function() return false end,
  detect = function() return false end, detectUp = function() return false end, detectDown = function() return false end,
}, { __index = function() return function() return true end end })

return M
