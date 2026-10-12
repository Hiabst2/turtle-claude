-- gohome: zurueck zum Heimplatz und in die Truhe dahinter ausladen
local nav = require("nav")
local ok, err = nav.goHome()
if not ok then printError(err) return end
local unloaded, info = nav.unload()
print(unloaded and ("Ausgeladen: " .. info .. " Items") or info)
