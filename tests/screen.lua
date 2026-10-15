-- tests/screen.lua - simulierter CC-Bildschirm fuer Lesbarkeitstests
-- term.write schreibt ab dem Cursor und schneidet am Rand ab (gezaehlt in clipped), write/print brechen wie
-- CC an Wortgrenzen um und scrollen in der letzten Zeile (gezaehlt in scrolled).

local M = {}

function M.new(w, h)
  local s = { w = w, h = h, x = 1, y = 1, rows = {}, scrolled = 0, clipped = 0 }
  local function blank() return (" "):rep(w) end
  for i = 1, h do s.rows[i] = blank() end

  local t = {}
  function t.getSize() return w, h end
  function t.getCursorPos() return s.x, s.y end
  function t.setCursorPos(x, y) s.x, s.y = math.floor(x), math.floor(y) end
  function t.clear() for i = 1, h do s.rows[i] = blank() end end
  function t.clearLine() if s.y >= 1 and s.y <= h then s.rows[s.y] = blank() end end
  function t.setTextColor() end
  t.setTextColour, t.setBackgroundColor, t.setBackgroundColour = t.setTextColor, t.setTextColor, t.setTextColor
  function t.isColor() return true end
  function t.write(text)
    text = tostring(text)
    if s.y >= 1 and s.y <= h then
      local row = s.rows[s.y]
      for i = 1, #text do
        local x = s.x + i - 1
        if x >= 1 and x <= w then
          row = row:sub(1, x - 1) .. text:sub(i, i) .. row:sub(x + 1)
        elseif x > w then
          s.clipped = s.clipped + 1
        end
      end
      s.rows[s.y] = row
    end
    s.x = s.x + #text
  end
  function t.scroll(n)
    for _ = 1, n do
      table.remove(s.rows, 1)
      s.rows[h] = blank()
      s.scrolled = s.scrolled + 1
    end
  end
  s.term = t

  -- wie write() aus dem CC-BIOS: Wortumbruch, lange Woerter hart geteilt, Scrollen in der letzten Zeile
  function s.write(text)
    text = tostring(text)
    local function newLine()
      if s.y + 1 <= h then s.x, s.y = 1, s.y + 1 else s.x, s.y = 1, h t.scroll(1) end
    end
    while #text > 0 do
      local ws = text:match("^[ \t]+")
      if ws then t.write(ws) text = text:sub(#ws + 1) end
      if text:sub(1, 1) == "\n" then newLine() text = text:sub(2) end
      local word = text:match("^[^ \t\n]+")
      if word then
        text = text:sub(#word + 1)
        if #word > w then
          while #word > 0 do
            if s.x > w then newLine() end
            t.write(word)
            word = word:sub(w - (s.x - #word) + 2)
          end
        else
          if s.x + #word - 1 > w then newLine() end
          t.write(word)
        end
      end
    end
  end
  function s.print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    s.write(table.concat(parts, " ") .. "\n")
  end
  -- sichtbarer Text einer Zeile (ohne Leerzeichen am Ende)
  function s.line(i) return (s.rows[i]:gsub("%s+$", "")) end
  function s.dump()
    local out = {}
    for i = 1, h do out[i] = "|" .. s.rows[i] .. "|" end
    return table.concat(out, "\n")
  end
  return s
end

-- fn mit diesem Bildschirm als term/print/write ausfuehren, danach alles zuruecksetzen
function M.run(s, fn)
  local oldTerm, oldPrint, oldWrite = term, print, write
  term, print, write = s.term, s.print, s.write
  local ok, err = pcall(fn)
  term, print, write = oldTerm, oldPrint, oldWrite
  assert(ok, err)
end

return M
