-- sethome: aktuelle Position wird zum Heimplatz. Die Truhe gehoert direkt hinter die Turtle.
local nav = require("nav")
nav.setHome()
print("Heimplatz gesetzt. " .. nav.where())
