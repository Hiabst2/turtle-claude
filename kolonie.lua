-- kolonie [thema]: zeigt Infos aus der MineColonies-Kolonie
-- Themen: overview requests citizens buildings workorders research visitors
local colony = require("colony")
local topic = ... or "overview"
textutils.pagedPrint(colony.query(topic))
