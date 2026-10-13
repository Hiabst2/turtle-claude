-- tests/net.lua - simuliertes Funknetz fuer TurtleMQ-Tests
-- Verliert, verdoppelt und vertauscht Pakete nach Wunsch (reproduzierbar ueber seed).
-- link.down = true simuliert ein Geraet ohne Modem (sendet und empfaengt nichts).

local M = {}

local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

local function rng(seed)
  local s = seed
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

M.clock = 1000000
function M.now() return M.clock end
function M.advance(ms) M.clock = M.clock + ms end

-- receive() laesst zuerst alle anderen Knoten ihre Warteschlange abarbeiten (die schicken dabei ACKs)
-- und liefert dann das naechste Paket fuer diesen Knoten.
function M.new(o)
  o = o or {}
  local rnd = rng(o.seed or 42)
  local net = { links = {}, transmitted = 0 }
  function net.link()
    local link = { queue = {} }
    function link.transmit(packet)
      if link.down then return end
      net.transmitted = net.transmitted + 1
      for _, other in ipairs(net.links) do
        if other ~= link and not other.down and rnd() >= (o.loss or 0) then
          for _ = 1, (rnd() < (o.dup or 0)) and 2 or 1 do
            if rnd() < (o.reorder or 0) then
              table.insert(other.queue, 1, copy(packet))
            else
              other.queue[#other.queue + 1] = copy(packet)
            end
          end
        end
      end
    end
    function link.receive()
      if link.down then return nil end
      net.pump(link)
      return table.remove(link.queue, 1)
    end
    net.links[#net.links + 1] = link
    return link
  end
  function net.pump(except)
    for _, other in ipairs(net.links) do
      if other ~= except and other.node and not other.down then
        while #other.queue > 0 do other.node:handle(table.remove(other.queue, 1)) end
      end
    end
  end
  -- neuer mq-Knoten mit eigener Computer-ID und eigenem Ordner
  function net.node(id, extra)
    local link = net.link()
    local opts = { id = id, dir = "/n" .. id .. "/.mq", link = link, now = M.now }
    for k, v in pairs(extra or {}) do opts[k] = v end
    local n = require("mq").new(opts)
    link.node = n
    return n
  end
  return net
end

return M
