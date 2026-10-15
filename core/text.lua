-- text.lua - Text fuer schmale CC-Bildschirme (Turtle 39x13, Computer 51x19)
-- wrap bricht wie CC an Wortgrenzen um, kann aber auf eine Zeilenzahl begrenzen; clip kuerzt eine Zeile.
-- Wer so vorbereitete Zeilen mit setCursorPos + term.write ausgibt, bekommt nie Scrollen oder Abschneiden.

local M = {}

-- Zeilen von hoechstens width Zeichen. maxRows: hoechstens so viele, die letzte endet dann mit "..."
function M.wrap(text, width, maxRows)
  local rows, row = {}, ""
  for word in tostring(text):gmatch("%S+") do
    -- Wort laenger als die Zeile (z.B. ein Pfad): hart teilen
    while #word > width do
      if row ~= "" then rows[#rows + 1], row = row, "" end
      rows[#rows + 1], word = word:sub(1, width), word:sub(width + 1)
    end
    if word ~= "" then
      if row == "" then
        row = word
      elseif #row + 1 + #word <= width then
        row = row .. " " .. word
      else
        rows[#rows + 1], row = row, word
      end
    end
  end
  if row ~= "" or #rows == 0 then rows[#rows + 1] = row end
  if maxRows and #rows > maxRows then
    local last = rows[maxRows]
    for i = #rows, maxRows + 1, -1 do rows[i] = nil end
    rows[maxRows] = (#last + 3 > width and last:sub(1, width - 3) or last) .. "..."
  end
  return rows
end

-- eine Zeile auf width Zeichen kuerzen
function M.clip(text, width)
  text = tostring(text)
  if #text <= width then return text end
  return text:sub(1, width - 3) .. "..."
end

-- Wert als Text mit sortierten Schluesseln: gleicher Inhalt ergibt immer denselben Text (zum Vergleichen)
function M.canonical(v)
  if type(v) ~= "table" then return type(v) == "string" and ("%q"):format(v) or tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. M.canonical(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Zeilen { text, farbe } ab Zeile y zeichnen (jede Zeile wird vorher geleert)
function M.draw(rows, y)
  for i, r in ipairs(rows) do
    term.setCursorPos(1, (y or 1) + i - 1)
    term.clearLine()
    if r[2] then term.setTextColor(r[2]) end
    term.write(r[1])
  end
end

return M
