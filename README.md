# turtle-claude

Eine Mining Turtle (CC:Tweaked) mit Claude als Gehirn: Spieler reden per Chat mit ihr,
Claude steuert sie über Tools und nutzt fertige Programme für größere Aufgaben.

## Installation

Auf jeder neuen Turtle bzw. jedem neuen Computer:

```
wget run https://raw.githubusercontent.com/Hiabst2/turtle-claude/main/bootstrap.lua
```

Der Bootstrap fragt die Rolle ab und richtet alles ein:

| Rolle | Gerät | Inhalt |
|---|---|---|
| `turtle` | Turtle | Claude-Turtle: Chat, Mining, Kolonie (fragt API-Key, Besitzer, Name) |
| `miner` | Turtle | Mining-Programme ohne Claude, Bedienung im Terminal |
| `gps` | Computer | GPS-Sender (fragt die eigenen Koordinaten) |
| `gateway` | Computer | TurtleMQ-Gateway mit Statusanzeige aller Geräte (Ender Modem, Chunk dauerhaft laden) |

Später reicht `update`. Es lädt nur die Dateien der eigenen Rolle (`manifests/<rolle>.txt`), alle vom
selben Commit, und tauscht erst aus, wenn alles da ist. `version` zeigt, was installiert ist.
Rolle und Kanal ändern: `set claude.role <rolle>`, `set claude.channel <branch>`, dann `update`.

## Programme

| Programm | Zweck |
|---|---|
| `claude` | Chat mit Claude (Terminal oder Advanced-Peripherals-Chat-Box). `stop` bricht ab. |
| `stripmine [länge] [seitengang] [abstand]` | Stripmine mit Erzadern, Ausladen und Heimweg |
| `tunnel [länge] [breite] [höhe]` | Tunnel graben (Turtle = untere linke Ecke) |
| `gohome` | Heimfahren und in die Truhe hinter dem Heimplatz ausladen |
| `setdepot` | Aktuelle Position wird Lagerplatz (Ausladen + Kohle) |
| `sethome` | Aktuelle Position wird Heimplatz |
| `goto x y z` | Zu einer Koordinate fahren |
| `gpsfix` | Per GPS auf Weltkoordinaten umstellen (Modem im Inventar) |
| `kolonie [thema]` | MineColonies-Infos: overview, requests, citizens, buildings, workorders, research, visitors |
| `zone list / add / here / del / maxy` | Wo gegraben werden darf (Weltkoordinaten, GPS nötig) |
| `orehunt [bereiche] [radius]` | Erzjagd mit dem Geo Scanner: Wegsuche durch Höhlen und eigene Gänge, so wenig Stein wie möglich; Scan-Bereiche ohne Überschneidung |
| `update [force]` | Programme der eigenen Rolle neu von GitHub laden |
| `version` | Installierte Version (Commit, Kanal, Rolle) |
| `bootstrap [rolle] [kanal]` | Gerät neu einrichten |
| `gateway` | TurtleMQ-Gateway (Rolle `gateway`, startet automatisch) |
| `mqtail [topic ...]` | TurtleMQ-Nachrichten live mitlesen, z.B. `mqtail worker.*` |

`nav.lua` und `mine.lua` sind Bibliotheken, die von den Programmen geladen werden.
Der API-Key liegt nur in den Turtle-Settings, nie im Repo.

## Sicherheit

Jeder Abbau wird in `nav.lua` geprüft, egal ob von Claude, Stripmine oder Heimweg:

- nur mit GPS, nur innerhalb einer Mining-Zone, nie über dem Höhenlimit (Standard Y 50)
- ohne Zone gräbt die Turtle gar nicht
- Truhen, Kolonie-Blöcke, Computer, Türen, Glas, Create-Maschinen usw. nie

Per Chat darf nur der Besitzer (`set claude.owner <Name>`) die Turtle steuern, Fragen darf jeder stellen.
Zonen und Höhenlimit ändert sie per Chat erst, wenn der Besitzer mit „ja“ bestätigt. Im Terminal mit `zone`.

`startup.lua` startet `claude` nach jedem Neustart und setzt unterbrochene Aufträge fort.
Zustandsdateien (`/.nav`, `/.zones`, `/.job`) werden mit Sicherung gespeichert; ist eine kaputt,
meldet die Turtle das, statt still neu anzufangen.

## Heimplatz-Aufbau (`sethome`)

- **unter** der Turtle: Ausrüstungskiste (Toolbox) mit Geo Scanner, Player Detector, Ender Modem, Zwischenkiste
- **neben** der Turtle: Colony Integrator (optional)
- **hinter** der Turtle: Truhe zum Ausladen (nur wenn es keinen eigenen Lagerplatz gibt)
- **über** dem Heimplatz frei bis zur Reisehöhe (Standard Y 110, `set claude.travel_y <y>`)

Die Chat Box bleibt immer angelegt. Für Scanner, Detector und Modem wird kurz die Spitzhacke getauscht.

## Lagerplatz (optional, `setdepot`)

Eigener Platz zum Ausladen und Tanken, z.B. am Tom's-Storage-Lager:

- **hinter** der Turtle: *Inventory Cable Connector* – alles wird reingeworfen (eigene Kohle bis auf einen Stapel)
- **unter, rechts oder links**: *Filtered Cable Connector* mit Filter Kohle – davon wird nachgetankt (bis 5000, `set claude.fuel_target`)
- **über** dem Lagerplatz frei bis zur Reisehöhe

## TurtleMQ (Nachrichten zwischen Geräten)

Ein Gateway-Computer (Rolle `gateway`) sammelt Nachrichten und zeigt den Status aller Geräte.
Turtles melden sich per Heartbeat mit Position, Fuel, Auftrag und Version:

```
set mq.enabled true      einschalten (Standard: aus)
set mq.interval 60       Sekunden zwischen zwei Syncs
set mq.channel 4242      Funkkanal (überall gleich einstellen)
set mq.secret <text>     Geheimnis für die Signatur (überall gleich, fragt auch der Bootstrap)
```

Mit Geheimnis trägt jede Nachricht eine HMAC-SHA256-Signatur, auch ACKs. Nachrichten ohne gültige
Signatur werden verworfen; das Gateway zeigt an, von wem zuletzt etwas abgelehnt wurde.

Die Turtle braucht ein Wireless/Ender Modem im Inventar. Für jeden Sync wird es kurz statt der Spitzhacke
angelegt, die Chat Box bleibt dran. Gesynct wird nur an sicheren Stellen: zwischen zwei Mining-Schritten,
im Leerlauf von `claude` und am Ende eines Auftrags. Nachrichten gehen nicht verloren, auch wenn die Turtle
länger kein Signal hat; Post vom Gateway holt sie beim nächsten Sync ab.

## Entwicklung

- Neue Datei: in die passenden `manifests/*.txt` eintragen. `files.txt` ist nur noch für alte
  `update`-Versionen da und muss dem Turtle-Manifest entsprechen (prüft ein Test).
- Tests ohne Minecraft (braucht Lua 5.2): `sh tests/test.sh`

## Zwischenkiste

Liegt eine normale Kiste im Inventar der Turtle, stellt sie beim Start von `stripmine`, `tunnel` oder `orehunt`
die Kiste unter sich ab und legt dort die Ausrüstung ab, die sie beim Minen nicht braucht (bei `orehunt` bleibt
der Geo Scanner dabei). Während des Auftrags wird die Kiste nicht angefasst. Am Ende holt die Turtle alles raus,
baut die Kiste ab und legt sie nach der Heimfahrt mit der Ausrüstung zurück in die Toolbox.
Bei `stop` bleibt die Kiste stehen.
