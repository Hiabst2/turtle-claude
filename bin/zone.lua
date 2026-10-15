-- zone: legt fest, wo die Turtle graben darf (Weltkoordinaten aus F3, GPS noetig)
--   zone list
--   zone add <name> <x1> <y1> <z1> <x2> <y2> <z2>
--   zone here <name> <radius> [runter=0] [hoch=1]   Quader um die Turtle
--   zone del <name>
--   zone maxy <y>                                     Hoehenlimit (Standard 50)
local zones = require("zones")
local nav = require("nav")
local args = { ... }
local cmd = args[1] or "list"

local ok, msg = true, nil
if cmd == "list" then
  msg = zones.describe()
elseif cmd == "add" then
  ok, msg = zones.add(args[2], args[3], args[4], args[5], args[6], args[7], args[8])
elseif cmd == "here" then
  if not nav.hasGps() then print("Erst gpsfix, Zonen brauchen Weltkoordinaten.") return end
  ok, msg = zones.addAround(args[2], nav.pos(), args[3], args[4], args[5])
elseif cmd == "del" then
  ok, msg = zones.delete(args[2])
elseif cmd == "maxy" then
  ok, msg = zones.setMaxY(args[2])
else
  msg = "zone list | add <name> x1 y1 z1 x2 y2 z2 | here <name> <radius> [runter] [hoch] | del <name> | maxy <y>"
end
if ok then print(msg) else printError(msg) end
