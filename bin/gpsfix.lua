-- gpsfix: Position und Blickrichtung per GPS bestimmen und auf Weltkoordinaten umstellen
local nav = require("nav")
local ok, err = nav.calibrate()
print(ok and ("GPS ok. " .. nav.where()) or err)
