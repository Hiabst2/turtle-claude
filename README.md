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
| `central` | Computer | Zentrale mit Job-Dienst: verteilt Aufträge an Miner (Ender Modem, Chunk dauerhaft laden) |
| `command` | Computer | Leitstelle: Claude mit Chat Box, steuert die Turtles über Aufträge (fragt API-Key, Besitzer, Name) |

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

Claude kann den Status aller Geräte beim Gateway abfragen („Hiabszt, wie geht's den anderen Turtles?“):
Name, Rolle, Zustand, Position, Fuel, Auftrag, wartende Post. Das Gateway warnt bei doppelten Namen.
Miner-Turtles ohne Claude melden sich vorerst nur während eines Auftrags (Leerlauf-Dienst kommt mit P3).

Die Turtle braucht ein Wireless/Ender Modem im Inventar. Für jeden Sync wird es kurz statt der Spitzhacke
angelegt, die Chat Box bleibt dran. Gesynct wird nur an sicheren Stellen: zwischen zwei Mining-Schritten,
im Leerlauf von `claude` und am Ende eines Auftrags. Nachrichten gehen nicht verloren, auch wenn die Turtle
länger kein Signal hat; Post vom Gateway holt sie beim nächsten Sync ab.

## Zentrale und Aufträge (P3)

Die Zentrale (Rolle `central`) verteilt Aufträge an Miner-Turtles. Miner mit TurtleMQ starten den
Worker-Dienst (`worker`) automatisch: Er meldet sich frei, bekommt beim nächsten Sync einen passenden
Auftrag, arbeitet ihn mit den normalen Programmen ab (alle Schutzregeln gelten) und meldet Fortschritt.

Auftrag anlegen in der Eingabezeile der Zentrale, z.B.:

```
add orehunt x=725 y=40 z=630 f=nord rounds=2 area=700,0,600,750,60,650
add tunnel x=710 y=40 z=610 f=sued length=20 width=3 height=3 prio=8
list
cancel J3
```

- Zuteilung nach Rolle und Ausrüstung (Erzjagd nur mit Geo Scanner), Priorität vor Alter
- Lease: meldet sich ein Worker 5 Minuten nicht, geht der Auftrag zurück in die Warteschlange;
  kommt der alte Worker zurück, wird er gestoppt
- Aufträge mit überlappendem Bereich (`area`) laufen nie gleichzeitig
- nach 3 Fehlschlägen ist ein Auftrag endgültig gescheitert
- Worker: `P` pausiert (keine neuen Aufträge), `Q` zurück zur Shell
- Aufträge bekommt nur, wer genug Fuel für Anfahrt, Arbeit und den Weg zum Lager hat (`cost.lua`);
  ein Worker unter `worker.min_fuel` (Standard 1000) fährt im Leerlauf selbst zum Lager tanken

Zonen und Orte pflegt die Zentrale (Map-Dienst) und verteilt sie bei jedem Sync an die Turtles.
Jede Turtle prüft weiterhin jeden Block selbst mit ihrer Kopie. Solange die Zentrale keine Zonen hat,
gelten die lokalen.

```
zone add mine1 700 0 600 750 60 650     zone del mine1     zone maxy 50     zone list
place depot 740 64 615 nord             place home Miner1 730 70 640 ost   place del depot
```

`depot` ist der gemeinsame Lagerplatz aller Turtles, `home <Name>` der Heimplatz einer Turtle
(Blickrichtung = wohin die Turtle auf dem Platz schaut).

## Leitstelle (Command-Node)

Claude läuft auf einem Computer mit Chat Box und Ender Modem (Rolle `command`) und steuert die Turtles nur
über Aufträge an die Zentrale. Beispiele im Chat:

- „Leitstelle, lass eine Turtle in mine1 nach Erz suchen, 2 Bereiche“
- „Leitstelle, was läuft gerade?“ / „Wie geht's den Turtles?“ / „Zeig mir die Zonen“
- „Leitstelle, brich J3 ab“
- „Leitstelle, leg eine Zone mine2 an …“ → muss der Besitzer mit „ja“ bestätigen

Fertige und gescheiterte Aufträge meldet die Leitstelle von selbst im Chat. Steuern darf nur der Besitzer,
Fragen darf jeder stellen. Mit Colony Integrator am Computer beantwortet sie auch Fragen zur Kolonie.
Die All-in-one-Turtle (`claude`, Rolle `turtle`) ist Altlast und wird nicht mehr weiterentwickelt.

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
