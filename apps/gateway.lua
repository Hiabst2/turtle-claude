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

-- der Bildschirm steht in broker.lua (Broker:draw, dort prueft ihn ein Test auf 51x19)
local function draw() b:draw(settings.get("mq.channel", mq.CHANNEL)) end

while true do
  b:step(1) -- empfangen, verteilen, Post an wer sich gemeldet hat (siehe broker.lua)
  draw()
end
