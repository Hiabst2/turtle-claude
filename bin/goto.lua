-- goto <x> <y> <z>: faehrt hin und graebt sich notfalls durch
local nav = require("nav")
local x, y, z = tonumber((...)), tonumber(select(2, ...)), tonumber(select(3, ...))
if not (x and y and z) then print("goto <x> <y> <z>") return end
local ok, err = nav.goTo(x, y, z)
print(ok and nav.where() or err)
