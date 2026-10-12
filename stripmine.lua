-- stripmine [laenge] [seitengang] [abstand]
-- Beispiel: stripmine 48 10 3  -> 48 Bloecke Hauptgang, alle 3 Bloecke 10 Bloecke nach links und rechts
local mine = require("mine")
local args = { ... }
if args[1] == "?" then print("stripmine [laenge=32] [seitengang=8] [abstand=3]") return end
print(mine.run(mine.stripmine, { length = args[1], branch = args[2], spacing = args[3] }, print))
