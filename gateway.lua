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
  if node.rejected > 0 then
    term.setTextColor(colors.orange)
    local from = b.state.devices[node.lastRejected]
    print(("%d Paket(e) mit falscher/fehlender Signatur abgelehnt, zuletzt von %s"):format(node.rejected,
      from and from.label or ("#" .. tostring(node.lastRejected))))
  end
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
  -- Geraete mit Namen statt Computer-ID anzeigen, soweit bekannt
  local function name(id)
    local d = b.state.devices[id]
    return d and d.label or tostring(id)
  end
  for i = 1, math.min(#b.log, 5) do
    local e = b.log[i]
    print(("%s -> %s  %s"):format(name(e.source), name(e.target), tostring(e.topic)))
  end
  term.setTextColor(colors.white)
end

while true do
  b:step(1) -- empfangen, verteilen, Post an wer sich gemeldet hat (siehe broker.lua)
  draw()
end
