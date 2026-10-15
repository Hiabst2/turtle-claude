-- gohome: am Lagerplatz ausladen und Kohle tanken, dann heim
local nav = require("nav")
local ok, err = nav.goDepot()
if not ok then printError(err) return end
local unloaded, info = nav.unload()
print(unloaded and ("Ausgeladen: " .. info .. " Items, Fuel " .. tostring(nav.fuel())) or info)
ok, err = nav.goHome()
print(ok and nav.where() or err)
