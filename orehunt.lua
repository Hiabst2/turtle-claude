-- orehunt [bereiche] [radius]: Erzjagd mit dem Geo Scanner (muss im Inventar sein)
-- Scannt, graebt gezielt zu den Erzen in den Mining-Zonen und rueckt pro Runde in Blickrichtung vor.
local mine = require("mine")
local args = { ... }
if args[1] == "?" then print("orehunt [runden=4] [radius=8]") return end
print(mine.run(mine.orehunt, { rounds = args[1], radius = args[2] }, print))
