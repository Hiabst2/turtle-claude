-- tunnel [laenge] [breite] [hoehe]
-- Die Turtle steht unten links, der Tunnel geht nach rechts und oben.
local mine = require("mine")
local args = { ... }
if args[1] == "?" then print("tunnel [laenge=16] [breite=3] [hoehe=3]") return end
print(mine.run(mine.tunnel, { length = args[1], width = args[2], height = args[3] }, print))
