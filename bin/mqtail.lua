-- mqtail [topic ...]: zeigt TurtleMQ-Nachrichten live an (Standard: alle). Braucht ein Wireless/Ender Modem,
-- also einen Computer oder Pocket Computer. Beispiel: mqtail worker.*
local mq = require("mq")

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then printError("Kein Wireless/Ender Modem angeschlossen.") return end

local topics = { ... }
if #topics == 0 then topics = { "*" } end

-- eigener Ordner, damit mqtail einem anderen Programm auf demselben Geraet nichts wegnimmt
local node = mq.new({ link = mq.modemLink(modem), dir = "/.mqtail" })
node:register({}, { label = (os.getComputerLabel() or "mqtail"), role = "tail" })
node:subscribe(topics)
print("Lese mit: " .. table.concat(topics, " ") .. "  (Strg+T beendet)")

while true do
  node:flush()
  node:poll(1)
  node:process(function(m)
    local payload = type(m.payload) == "table" and textutils.serialize(m.payload, { compact = true })
      or tostring(m.payload)
    term.setTextColor(colors.yellow)
    write(("[%s] "):format(tostring(m.topic)))
    term.setTextColor(colors.white)
    print(("%s -> %s: %s"):format(tostring(m.source), tostring(m.target), payload))
  end)
end
