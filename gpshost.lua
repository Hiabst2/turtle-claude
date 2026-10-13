-- gpshost: dieser Computer ist ein GPS-Sender. Koordinaten kommen aus den Settings (setzt bootstrap):
--   set gps.x 100   set gps.y 250   set gps.z 200
local x, y, z = settings.get("gps.x"), settings.get("gps.y"), settings.get("gps.z")
if not (x and y and z) then
  printError("Koordinaten fehlen. Mit F3 den Computer-Block anschauen und setzen:")
  print("  set gps.x <x>   set gps.y <y>   set gps.z <z>")
  return
end
shell.run("gps", "host", tostring(x), tostring(y), tostring(z))
