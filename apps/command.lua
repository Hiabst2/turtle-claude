-- command: Leitstelle (Command-Node). Claude auf einem Computer mit Chat Box und Wireless/Ender Modem.
-- Steuert die Turtles ueber Auftraege an die Zentrale. Setup:
--   set claude.key sk-ant-...     set claude.owner <Minecraft-Name>     label set <Name fuer den Chat>
-- Optional: Colony Integrator am Computer fuer Fragen zur Kolonie.
local mq = require("mq")
local commander = require("commander")

local KEY = settings.get("claude.key")
if not KEY then print("Kein API-Key. Setzen mit:\n  set claude.key sk-ant-...") return end
if not http then printError("HTTP ist in der ComputerCraft-Config deaktiviert.") return end
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then printError("Kein Wireless/Ender Modem angeschlossen.") return end
local chatBox = peripheral.find("chatBox")
local integrator = peripheral.find("colonyIntegrator") or peripheral.find("colony_integrator")

local name = os.getComputerLabel() or "Leitstelle"
local c = commander.new({
  node = mq.new({ link = mq.modemLink(modem), names = { "command" } }),
  name = name,
  owner = settings.get("claude.owner"),
  key = KEY,
  model = settings.get("claude.model"), -- leer: Standard aus agent.lua
  effort = settings.get("claude.effort"), -- leer: Standard aus agent.lua (low)
  chatBox = chatBox,
  colony = integrator and require("colony") or nil,
  debug = settings.get("claude.debug", false),
})
c.start()

term.clear()
term.setCursorPos(1, 1)
print(name .. " (Leitstelle) ist online. " .. c.tools.status())
print(chatBox and ("Im Chat mit \"" .. name .. ", ...\" ansprechen.") or "Keine Chat Box: hier tippen.")

-- Nur diese Koroutine benutzt TurtleMQ und Claude; Chat und Terminal reihen nur ein.
local function worker()
  while true do
    c.agent:step()
    local ok, err = pcall(c.tick, 1)
    if not ok then printError("TurtleMQ: " .. tostring(err)) end
  end
end

local function chatLoop()
  while true do
    local _, user, msg = os.pullEvent("chat")
    c.agent:chatMessage(user, msg)
  end
end

local function terminalLoop()
  while true do
    local line = read()
    if line and line ~= "" then c.agent:enqueue(nil, line, false) end
  end
end

if chatBox then
  parallel.waitForAny(worker, chatLoop, terminalLoop)
else
  parallel.waitForAny(worker, terminalLoop)
end
