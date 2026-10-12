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
| `update` | Alles neu von GitHub laden |

`nav.lua` und `mine.lua` sind Bibliotheken, die von den Programmen geladen werden.
Der API-Key liegt nur in den Turtle-Settings, nie im Repo.
