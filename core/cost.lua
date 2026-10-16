-- cost.lua - Fuel-Schaetzungen, gemeinsam fuer Turtle (nav), Job-Dienst und Path-Dienst
-- Reine Rechnung ohne Zustand, damit alle mit derselben Formel arbeiten.

local M = {}

M.TRAVEL_Y = 110
M.RESERVE = 200 -- Puffer, den eine Turtle nach einem Auftrag noch haben soll

-- Weg so, wie nav.travel ihn fliegt: kurze Wege direkt, weite hoch auf Reisehoehe und wieder runter
function M.trip(from, to, travelY)
  local horizontal = math.abs(from.x - to.x) + math.abs(from.z - to.z)
  if horizontal <= 8 then return horizontal + math.abs(from.y - to.y) end
  local ty = math.max(travelY or M.TRAVEL_Y, from.y)
  return (ty - from.y) + horizontal + math.abs(ty - to.y)
end

-- grobe Schaetzung, wie viele Schritte ein Auftrag selbst braucht (ohne An- und Abfahrt)
function M.jobBudget(jobType, params)
  params = params or {}
  local n = function(v, d) return tonumber(v) or d end
  if jobType == "tunnel" then
    local l, w, h = n(params.length, 16), n(params.width, 3), n(params.height, 3)
    return l * (w * h + w + h) -- jede Scheibe: abfahren und zurueck
  elseif jobType == "stripmine" then
    local l, b, s = n(params.length, 32), n(params.branch, 8), n(params.spacing, 3)
    return l + math.floor(l / s) * 4 * b + l -- Hauptgang, Seitengaenge hin und zurueck, Rueckweg
  elseif jobType == "stonehunt" then
    return math.ceil(n(params.amount, 640) / 3) * 2 -- 3 Bloecke je Schritt, grob hin und zurueck
  elseif jobType == "orehunt" then
    local rounds, radius = n(params.rounds, 4), n(params.radius, 8)
    return rounds * (radius * 2 + radius * radius) -- zwischen Bereichen plus Wege zu den Erzen
  end
  return 0
end

-- Fuel, das ein Worker fuer einen Auftrag mitbringen sollte: Anfahrt, Arbeit, danach bis zum Lager
function M.need(job, worker, travelY)
  local start = job.params and job.params.start
  if job.type == "goto" and job.params then start = job.params end
  local total = M.RESERVE + M.jobBudget(job.type, job.params)
  if start and start.x and worker.pos then
    if worker.needs_home and worker.home then
      -- Ausruestung liegt daheim in der Toolbox: Umweg ueber den Heimplatz
      total = total + M.trip(worker.pos, worker.home, travelY) + M.trip(worker.home, start, travelY)
    else
      total = total + M.trip(worker.pos, start, travelY)
    end
    if worker.depot then total = total + M.trip(start, worker.depot, travelY) end
  end
  return total
end

return M
