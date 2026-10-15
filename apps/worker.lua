-- worker: Worker-Dienst fuer Miner-Turtles. Holt Auftraege von der Zentrale und arbeitet sie ab.
-- Braucht TurtleMQ (set mq.enabled true) und ein Wireless/Ender Modem im Inventar.
--   P = pausieren (keine neuen Auftraege, z.B. fuer Handarbeit) / weiter
--   Q = zurueck zur Shell (ein laufender Auftrag wird beim naechsten Start fortgesetzt)
local runner = require("jobrunner")
local sync = require("sync")

if not sync.enabled() then
  printError("TurtleMQ ist aus. Einschalten: set mq.enabled true")
  return
end
runner.init()

-- der Bildschirm steht in jobrunner.draw (dort prueft ihn ein Test auf 39x13)
local draw = runner.draw

local function work()
  while true do
    draw()
    runner.safeStep() -- Fehler werden angezeigt, der Dienst laeuft weiter
    draw()
    sleep(1)
  end
end

local function keys()
  while true do
    local _, ch = os.pullEvent("char")
    if ch == "p" or ch == "P" then
      runner.togglePause()
      draw()
    elseif ch == "q" or ch == "Q" then
      return
    end
  end
end

parallel.waitForAny(work, keys)
term.clear()
term.setCursorPos(1, 1)
print("Worker beendet. Neu starten mit: worker")
