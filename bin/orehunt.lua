-- orehunt [bereiche] [radius]: Erzjagd mit dem Geo Scanner (muss im Inventar sein)
-- Scannt Bereiche auf einem Raster ohne Ueberschneidung und holt die Erze in den Mining-Zonen
-- ueber Wege, die moeglichst wenig Stein kosten (Hoehlen und eigene Gaenge zuerst).
local mine = require("mine")
local args = { ... }
if args[1] == "?" then print("orehunt [bereiche=4] [radius=8]") return end
print(mine.run(mine.orehunt, { rounds = args[1], radius = args[2] }, print))
