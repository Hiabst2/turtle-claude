-- services.lua - Service-Host der Zentrale
-- Mehrere Dienste (job, spaeter map, path) laufen auf einem Computer unter eigenen Namen. Sie reden nur
-- ueber TurtleMQ-Nachrichten miteinander; liegt das Ziel auf demselben Computer, wird lokal zugestellt
-- statt gefunkt. So laesst sich jeder Dienst spaeter ohne Codeaenderung auf einen eigenen Computer legen.

local M = {}

-- Welcher Dienst ist fuer ein Topic zustaendig (wenn die Nachricht nicht direkt an einen Namen geht)?
M.OWNER = {
  { prefix = "job.", service = "job" },
  { prefix = "worker.idle", service = "job" },
  { prefix = "map.", service = "map" },
  { prefix = "path.", service = "path" },
}

M.HEARTBEAT = 60 -- Sekunden

function M.new(node, opts)
  opts = opts or {}
  local host = { node = node, services = {}, byName = {}, label = opts.label or "Zentrale" }
  host.now = node.now

  function host.add(name, service)
    host.services[#host.services + 1] = { name = name, service = service }
    host.byName[name] = service
    node.names[name] = true
  end

  function host.send(target, topic, payload, sendOpts)
    if type(target) == "string" and host.byName[target] then
      return node:deliverLocal(target, topic, payload, sendOpts)
    end
    return node:send(target, topic, payload, sendOpts)
  end

  function host.dispatch(msg)
    local service = host.byName[msg.target]
    if not service then
      for _, rule in ipairs(M.OWNER) do
        if (msg.topic or ""):sub(1, #rule.prefix) == rule.prefix then
          service = host.byName[rule.service]
          break
        end
      end
    end
    if service then service:handle(msg) end
  end

  local lastBeat
  -- beim Gateway anmelden und als "online" melden (die Zentrale hat ein festes Modem)
  function host.heartbeat(force)
    local now = host.now()
    if not force and lastBeat and now - lastBeat < M.HEARTBEAT * 1000 then return end
    lastBeat = now
    local names = {}
    for _, s in ipairs(host.services) do names[#names + 1] = s.name end
    node:drop(function(m) return m.topic == "worker.heartbeat" or m.topic == "mq.register" end)
    node:register(names, { label = host.label, role = "central", mode = "online" })
    node:send("gateway", "worker.heartbeat", { label = host.label, role = "central", mode = "online",
      interval = M.HEARTBEAT }, { ttl = 300 })
  end

  -- eine Runde: empfangen, verteilen, Dienste ticken lassen, senden
  function host.step(timeout)
    host.heartbeat()
    local backlog = #node:list("inbox") > 0
    node:poll(backlog and 0 or (timeout or 1), { quiet = 0.2 })
    node:process(host.dispatch)
    for _, s in ipairs(host.services) do
      if s.service.tick then s.service:tick() end
    end
    node:process(host.dispatch) -- lokal zugestellte Nachrichten aus dieser Runde gleich mit
    node:flush()
  end

  return host
end

return M
