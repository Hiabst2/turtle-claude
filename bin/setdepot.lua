-- setdepot: aktuelle Position wird zum Lagerplatz (Ausladen und Tanken).
-- Hinter der Turtle: Tom's Storage Cable Connector. Unter, links oder rechts: Filtered Connector mit Kohle.
local nav = require("nav")
nav.setDepot()
print("Lagerplatz gesetzt. " .. nav.where())
