# turtle-claude

Eine Mining Turtle (CC:Tweaked) mit Claude als Gehirn: Spieler reden per Chat mit ihr,
Claude steuert sie über Tools und nutzt fertige Programme für größere Aufgaben.

## Installation in der Turtle

```
wget https://raw.githubusercontent.com/Hiabst2/turtle-claude/main/update.lua update
update
label set Hiabst
set claude.key sk-ant-...
sethome
claude
```

Später reicht `update`, um alles auf den neuesten Stand zu bringen.

## Programme

| Programm | Zweck |
|---|---|
| `claude` | Chat mit Claude (Terminal oder Advanced-Peripherals-Chat-Box). `stop` bricht ab. |
| `stripmine [länge] [seitengang] [abstand]` | Stripmine mit Erzadern, Ausladen und Heimweg |
| `tunnel [länge] [breite] [höhe]` | Tunnel graben (Turtle = untere linke Ecke) |
| `gohome` | Heimfahren und in die Truhe hinter dem Heimplatz ausladen |
| `sethome` | Aktuelle Position wird Heimplatz |
| `goto x y z` | Zu einer Koordinate fahren |
| `gpsfix` | Per GPS auf Weltkoordinaten umstellen (Modem im Inventar) |
| `kolonie [thema]` | MineColonies-Infos: overview, requests, citizens, buildings, workorders, research, visitors |
| `zone list / add / here / del / maxy` | Wo gegraben werden darf (Weltkoordinaten, GPS nötig) |
| `orehunt [runden] [radius]` | Erzjagd mit dem Geo Scanner, gräbt gezielt zu Erzen |
| `update` | Alles neu von GitHub laden |

`nav.lua` und `mine.lua` sind Bibliotheken, die von den Programmen geladen werden.
Der API-Key liegt nur in den Turtle-Settings, nie im Repo.

## Sicherheit

Jeder Abbau wird in `nav.lua` geprüft, egal ob von Claude, Stripmine oder Heimweg:

- nur mit GPS, nur innerhalb einer Mining-Zone, nie über dem Höhenlimit (Standard Y 50)
- ohne Zone gräbt die Turtle gar nicht
- Truhen, Kolonie-Blöcke, Computer, Türen, Glas, Create-Maschinen usw. nie

Zonen ändern: im Terminal mit `zone`, per Chat nur der Besitzer (`set claude.owner <Name>`).

`startup.lua` startet `claude` nach jedem Neustart und setzt unterbrochene Aufträge fort.

## Heimplatz-Aufbau

- **hinter** der Turtle: Truhe zum Ausladen
- **unter** der Turtle: Ausrüstungskiste mit Geo Scanner, Player Detector, Ender Modem
- **neben** der Turtle: Colony Integrator (optional)
- **über** dem Heimplatz frei bis zur Reisehöhe (Standard Y 110, `set claude.travel_y <y>`)

Die Chat Box bleibt immer angelegt. Für Scanner, Detector und Modem wird kurz die Spitzhacke getauscht.
