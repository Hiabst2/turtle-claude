-- startet claude automatisch nach jedem Neustart (z.B. wenn der Chunk wieder geladen wird).
-- Ein unterbrochener Stripmine/Tunnel wird dann fortgesetzt.
if settings.get("claude.key") and fs.exists("claude.lua") then
  shell.run("claude")
end
