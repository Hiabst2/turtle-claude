-- pathsvc.lua - Path-Dienst der Zentrale (klein in P3): Wegkosten und Fuel schaetzen
-- Die eigentliche Wegsuche macht die Turtle lokal (path.lua); zentrales A* ueber die grosse Karte
-- kommt laut Roadmap erst in P10. Rechnet mit cost.lua, derselben Formel wie Turtle und Job-Dienst.
--
-- path.estimate { from, to, travel_y }        -> path.estimate.reply { fuel }
-- path.job { job = {type, params}, worker = {pos, depot} } -> path.job.reply { fuel }

local cost = require("cost")

local M = {}

local Service = {}
Service.__index = Service

function M.new(host)
  return setmetatable({ host = host }, Service)
end

local function isPos(p) return type(p) == "table" and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) end

function Service:handle(msg)
  local p = type(msg.payload) == "table" and msg.payload or {}
  local answer
  if msg.topic == "path.estimate" then
    if isPos(p.from) and isPos(p.to) then
      answer = { fuel = cost.trip(p.from, p.to, tonumber(p.travel_y)) }
    else
      answer = { error = "from und to brauchen x, y, z" }
    end
  elseif msg.topic == "path.job" then
    if type(p.job) == "table" then
      answer = { fuel = cost.need(p.job, type(p.worker) == "table" and p.worker or {}, tonumber(p.travel_y)) }
    else
      answer = { error = "job fehlt" }
    end
  else
    return false
  end
  self.host.send(msg.source, msg.topic .. ".reply", answer, { reply_to = msg.id })
  return true
end

return M
