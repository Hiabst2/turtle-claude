-- gateway: TurtleMQ-Broker. Laeuft dauerhaft auf einem Computer mit Wireless/Ender Modem
-- in einem dauerhaft geladenen Chunk (z.B. per FTB Chunks). Zeigt den Status aller Geraete.
local mq = require("mq")
local broker = require("broker")

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then printError("Kein Wireless/Ender Modem angeschlossen.") return end

local node = mq.new({
  link = mq.modemLink(modem),
  names = { "gateway" },
  accept = function() return true end, -- der Broker nimmt alles an und verteilt es
})
local b = broker.new(node)

local function draw()
  local w, h = term.getSize()
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  print(("TurtleMQ Gateway #%d  Kanal %d  Outbox %d"):format(node.id, settings.get("mq.channel", mq.CHANNEL),
    node:pending()))
  local dead = #node:list("dead")
  if dead > 0 then
    term.setTextColor(colors.red)
    print(dead .. " Nachricht(en) nicht verarbeitbar, siehe /.mq/dead/")
  end
  term.setTextColor(colors.white)
  local lines = b:statusLines()
  for i = 1, math.min(#lines, h - 8) do print(lines[i]) end
  term.setTextColor(colors.gray)
  print(("-"):rep(w))
  for i = 1, math.min(#b.log, 5) do
    local e = b.log[i]
    print(("%s -> %s  %s"):format(tostring(e.source), tostring(e.target), tostring(e.topic)))
  end
  term.setTextColor(colors.white)
end

while true do
  node:poll(1, { quiet = 0.2 }) -- nach einem Schwall schnell antworten
  local active = {}
  node:process(function(msg)
    active[msg.source] = true
    b:route(msg)
  end)
  -- wer sich gerade gemeldet hat, ist erreichbar: sofort seine Post schicken
  for id in pairs(active) do
    if node:pending(id) > 0 then node:flush({ target = id, force = true }) end
  end
  node:flush() -- normale Wiederholungen fuer alles andere
  draw()
end
