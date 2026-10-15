-- agent.lua - allgemeiner Claude-Agent fuer ComputerCraft (Chat, Tool-Schleife, Sicherheit)
-- Wird vom Command-Node genutzt (commander.lua). Enthaelt alle Stabilitaets-Fixes aus P0.5:
--   * Lua-Fehler in Tools werden zu Fehler-Ergebnissen, jedes tool_use bekommt ein tool_result,
--     ein abgebrochener Verlauf wird repariert (B1)
--   * steuern darf per Chat nur der Besitzer, fragen jeder (B3)
--   * Wiederholung bei 429/5xx/529/Timeout (B7), Chat-Ausgabe sauber geteilt (B6),
--     Ansprache nur mit Trennzeichen nach dem Namen (B10), Umlaute aus dem Terminal -> UTF-8
--   * "stop" bricht ab; Aenderungen, die eine Bestaetigung brauchen, fuehrt erst das "ja" des
--     Besitzers aus - geprueft hier im Code, nicht von Claude
--
-- Der Verlauf wird nur hinten ergaenzt, nie veraendert (Whitepaper 6.2). Neuere Modelle (ab Claude Opus 5.5)
-- pruefen das und lehnen einen veraenderten Verlauf ab; ausserdem bleibt so der Prompt-Cache gueltig.
-- Statt alte Nachrichten vorne abzuschneiden, beginnt nach SESSION_MESSAGES Eintraegen oder SESSION_IDLE
-- Sekunden Ruhe eine neue Sitzung mit leerem Verlauf. Ihre erste Nachricht bekommt eine kurze Lagemeldung,
-- die der Code zusammenbaut (opts.brief), nicht Claude. Text wird beim Eintreffen einmal nach UTF-8 gewandelt.
--
-- Tools liefern einen Text. Braucht eine Aenderung Bestaetigung, liefert das Tool
--   { confirm = "Beschreibung", apply = function() return "Ergebnis" end }

local M = {}

M.API = "https://api.anthropic.com/v1/messages"
M.MODEL = "claude-opus-5-5" -- Standard; set claude.model <id> waehlt ein anderes
M.EFFORT = "low" -- ausdruecklich setzen: der Standard der API haengt vom Modell ab
M.MAX_STEPS = 25
M.SESSION_MESSAGES = 20 -- Eintraege im Verlauf, ab denen die naechste Frage eine neue Sitzung beginnt
M.SESSION_IDLE = 15 * 60 -- Sekunden Ruhe, nach denen die naechste Frage eine neue Sitzung beginnt
M.MAX_TOOL_RESULT = 2000 -- Zeichen; laengere Tool-Ergebnisse werden gekuerzt (gehen bei jedem Aufruf mit)

local Agent = {}
Agent.__index = Agent

function M.new(opts)
  local self = setmetatable({}, Agent)
  self.name = opts.name or "Leitstelle"
  self.trigger = self.name:lower()
  self.owner = opts.owner
  self.key = opts.key
  self.model = opts.model or M.MODEL
  self.effort = opts.effort or M.EFFORT
  self.brief = opts.brief -- function() -> Lagemeldung fuer den Anfang einer Sitzung (oder nil)
  self.now = opts.now or function() return os.epoch("utc") end
  self.lastActivity = nil
  self.system = opts.system or ""
  self.tools = opts.tools or {}
  self.runTool = opts.runTool -- function(name, input, ctx) -> Text oder {confirm, apply}
  self.readOnly = opts.readOnly or function() return false end
  self.chatBox = opts.chatBox
  self.debug = opts.debug
  self.history, self.notes, self.queue = {}, {}, {}
  self.pending = nil -- vorgemerkte Aenderung { text, apply }
  self.stopRequested = false
  self.onStop = opts.onStop -- z.B. laufende Anfragen abbrechen
  return self
end

-- Text -------------------------------------------------------------------------

local function validUtf8(s)
  if utf8 and utf8.len then return utf8.len(s) ~= nil end
  return not s:find("[\128-\255]")
end

-- Das CC-Terminal liefert Umlaute als Latin-1-Bytes, die API will UTF-8
local function toUtf8(s)
  if validUtf8(s) then return s end
  return (s:gsub("[\128-\255]", function(c)
    local b = c:byte()
    return string.char(0xC0 + math.floor(b / 64), 0x80 + b % 64)
  end))
end

-- auf hoechstens max Bytes kuerzen, nie mitten in einem UTF-8-Zeichen
local function cutUtf8(s, max)
  if #s <= max then return s end
  local cut = max
  while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) <= 0xBF do cut = cut - 1 end
  return s:sub(1, cut)
end

-- Tool-Ergebnis fuer den Verlauf: gueltiges UTF-8 und begrenzte Laenge
local function toolText(text)
  text = toUtf8(tostring(text))
  if #text <= M.MAX_TOOL_RESULT then return text end
  return cutUtf8(text, M.MAX_TOOL_RESULT) .. ("\n... (gekuerzt, %d Zeichen insgesamt)"):format(#text)
end
M.toolText = toolText

-- am letzten Leerzeichen vor der Grenze teilen, nie mitten in einem UTF-8-Zeichen
function M.splitChat(text, max)
  local parts = {}
  text = text:gsub("%s+$", "")
  while #text > max do
    local cut = max
    local space = text:sub(1, max):match(".*()%s")
    if space and space > max / 2 then
      cut = space - 1
    else
      while cut > 1 and text:byte(cut + 1) and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) <= 0xBF do
        cut = cut - 1
      end
    end
    parts[#parts + 1] = text:sub(1, cut)
    text = text:sub(cut + 1):gsub("^%s+", "")
  end
  if #text > 0 then parts[#parts + 1] = text end
  return parts
end

function Agent:reply(text, toChat)
  term.setTextColor(colors.lime)
  print(self.name .. ": " .. text)
  term.setTextColor(colors.white)
  if not (toChat and self.chatBox) then return end
  for _, chunk in ipairs(M.splitChat(text, 240)) do
    for _ = 1, 5 do -- die Chat Box hat einen Cooldown
      if self.chatBox.sendMessage(chunk, self.name) then break end
      sleep(1)
    end
  end
end

function Agent:isOwner(user)
  if user == nil then return true end -- direkt am Terminal
  return self.owner ~= nil and user:lower() == self.owner:lower()
end

-- API ----------------------------------------------------------------------------

function Agent:call()
  local body = textutils.serializeJSON({
    model = self.model,
    max_tokens = 4096,
    system = self.system,
    tools = self.tools,
    cache_control = { type = "ephemeral" },
    output_config = { effort = self.effort },
    messages = self.history,
  }, { unicode_strings = true })
  local RETRY = { [429] = true, [500] = true, [502] = true, [503] = true, [529] = true }
  local waits = { 2, 5, 10 }
  for attempt = 1, #waits + 1 do
    local res, err, errRes = http.post({
      url = M.API,
      body = body,
      headers = { ["content-type"] = "application/json", ["x-api-key"] = self.key, ["anthropic-version"] = "2023-06-01" },
      timeout = 60,
    })
    if res then
      local text = res.readAll()
      res.close()
      return textutils.unserializeJSON(text)
    end
    local code, detail = nil, ""
    if errRes then
      code = errRes.getResponseCode and errRes.getResponseCode()
      detail = errRes.readAll() or ""
      errRes.close()
    end
    if not (code == nil or RETRY[code]) or attempt > #waits then
      return nil, tostring(err) .. " " .. detail
    end
    sleep(waits[attempt])
  end
end

-- Beginnt die naechste Frage eine neue Sitzung? (leerer Verlauf, Verlauf voll, oder lange Ruhe)
function Agent:sessionDue()
  if #self.history == 0 then return true end
  if #self.history >= M.SESSION_MESSAGES then return true end
  return self.lastActivity ~= nil and self.now() - self.lastActivity > M.SESSION_IDLE * 1000
end

-- Neue Sitzung: leerer Verlauf statt abgeschnittener (der alte bleibt unveraendert liegen, bis er verfaellt).
-- Liefert die Lagemeldung fuer die erste Nachricht.
function Agent:newSession()
  self.history = {}
  local lines = { "[System] Neue Sitzung, der fruehere Verlauf ist nicht mehr da." }
  if self.brief then
    local ok, text = pcall(self.brief)
    if ok and text and text ~= "" then lines[#lines + 1] = tostring(text) end
  end
  if self.pending then
    lines[#lines + 1] = "Wartet auf Bestaetigung des Besitzers: " .. self.pending.text
  end
  return table.concat(lines, "\n")
end

function Agent:closeOpenToolUses()
  local last = self.history[#self.history]
  if not (last and last.role == "assistant" and type(last.content) == "table") then return end
  local results = {}
  for _, block in ipairs(last.content) do
    if block.type == "tool_use" then
      results[#results + 1] = { type = "tool_result", tool_use_id = block.id, is_error = true,
        content = "Abgebrochen, das Tool wurde nicht fertig ausgefuehrt." }
    end
  end
  if #results > 0 then self.history[#self.history + 1] = { role = "user", content = results } end
end

function Agent:tool(name, input, user, say)
  if not self.readOnly(name, input) and not self:isOwner(user) then
    return self.owner and ("Nur " .. self.owner .. " darf etwas veraendern. Fragen beantworte ich aber gern.")
      or "Aendern per Chat ist aus, solange kein Besitzer gesetzt ist (Terminal: set claude.owner <Name>)."
  end
  local out = self.runTool(name, input, { user = user, say = say })
  if type(out) == "table" and out.confirm then
    if user == nil then return out.apply() end -- direkt am Terminal: keine Rueckfrage
    self.pending = { text = out.confirm, apply = out.apply }
    return "NICHT ausgefuehrt. Vorgemerkt: " .. out.confirm .. ". Das gilt erst, wenn " .. tostring(self.owner)
      .. " im Chat mit 'ja' bestaetigt. Frag genau das und aendere nichts, worum er nicht gebeten hat."
  end
  return tostring(out)
end

function Agent:handle(user, text, fromChat)
  self.stopRequested = false
  self:closeOpenToolUses()
  local content = user and ("[" .. user .. "] " .. text) or text
  if #self.notes > 0 then
    content = table.concat(self.notes, "\n") .. "\n" .. content
    self.notes = {}
  end
  if self:sessionDue() then content = self:newSession() .. "\n" .. content end
  self.lastActivity = self.now()
  self.history[#self.history + 1] = { role = "user", content = toUtf8(content) }
  local say = function(msg) self:reply(msg, fromChat) end

  for _ = 1, M.MAX_STEPS do
    local resp, err = self:call()
    if not resp or resp.type == "error" then
      self:reply("API-Fehler: " .. tostring(err or (resp.error and resp.error.message)), fromChat)
      return
    end
    self.lastActivity = self.now()
    if resp.stop_reason == "refusal" then
      -- abgelehnt: nichts in den Verlauf (eine leere Antwort waere beim naechsten Aufruf ein Fehler)
      local cat = type(resp.stop_details) == "table" and resp.stop_details.category or nil
      self:reply("Dazu antworte ich nicht" .. (cat and (" (abgelehnt: " .. tostring(cat) .. ")") or "")
        .. ". Frag gern anders.", fromChat)
      return
    end
    if type(resp.content) ~= "table" or #resp.content == 0 then return end
    self.history[#self.history + 1] = { role = "assistant", content = resp.content }
    local said, results = {}, {}
    for _, block in ipairs(resp.content or {}) do
      if block.type == "text" and block.text ~= "" then said[#said + 1] = block.text end
    end
    if #said > 0 then say(table.concat(said, " ")) end
    for _, block in ipairs(resp.content or {}) do
      if block.type == "tool_use" then
        term.setTextColor(colors.gray)
        print("[" .. block.name .. "]")
        term.setTextColor(colors.white)
        local ok, out = pcall(self.tool, self, block.name, block.input or {}, user, say)
        local result = { type = "tool_result", tool_use_id = block.id }
        if ok then
          result.content = toolText(out)
        else
          result.content, result.is_error = toolText("Fehler im Tool: " .. tostring(out)), true
        end
        if self.debug then print(result.content) end
        results[#results + 1] = result
      end
    end
    if #results > 0 then self.history[#self.history + 1] = { role = "user", content = results } end
    if resp.stop_reason ~= "tool_use" then return end
    if self.stopRequested then
      self.stopRequested = false
      return
    end
  end
  self:reply("Ich hoer hier mal auf, das waren zu viele Schritte.", fromChat)
end

-- Eingaben ------------------------------------------------------------------------

-- Aus Chat oder Terminal. Laeuft im Chat-/Terminal-Koroutine: nur Merker setzen und einreihen,
-- die eigentliche Arbeit macht step() im Worker.
function Agent:enqueue(user, text, fromChat)
  local low = text:lower()
  if low == "stop" or low == "stopp" or low == "halt" then
    self.stopRequested = true
    self.queue = {}
    if self.onStop then self.onStop() end
    self:reply("Ok, ich stoppe.", fromChat)
    return
  end
  if self.pending and user and self:isOwner(user) then
    local change = self.pending
    self.pending = nil
    if low == "ja" or low == "yes" or low == "ok" or low == "passt" then
      self.queue[#self.queue + 1] = { confirm = change, user = user, fromChat = fromChat }
      os.queueEvent("agent_msg")
      return
    end
  end
  self.queue[#self.queue + 1] = { user = user, text = text, fromChat = fromChat }
  os.queueEvent("agent_msg")
end

-- arbeitet die Warteschlange ab; true, wenn etwas zu tun war
function Agent:step()
  local did = false
  while #self.queue > 0 do
    did = true
    local m = table.remove(self.queue, 1)
    local ok, e
    if m.confirm then
      ok, e = pcall(function()
        local res = tostring(m.confirm.apply())
        self:reply(res, m.fromChat)
        self.notes[#self.notes + 1] = "[System] " .. m.user .. " hat bestaetigt (" .. m.confirm.text .. "): " .. res
      end)
    else
      ok, e = pcall(self.handle, self, m.user, m.text, m.fromChat)
    end
    if not ok then printError(e) end
  end
  return did
end

-- Chat-Nachricht pruefen: nach dem Namen muss ein Trennzeichen oder das Ende kommen
function Agent:chatMessage(user, msg)
  local after = msg:sub(#self.trigger + 1, #self.trigger + 1)
  if msg:lower():sub(1, #self.trigger) == self.trigger and (after == "" or after:match("[%s,:!.?]")) then
    local text = msg:sub(#self.trigger + 1):gsub("^[%s,:!]+", "")
    if text ~= "" then self:enqueue(user, text, true) end
  end
end

return M
