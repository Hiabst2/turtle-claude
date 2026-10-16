# turtle-claude

Mining-Turtles für CC:Tweaked, die Aufträge von einer Zentrale abarbeiten. Claude sitzt als Leitstelle
auf einem Computer mit Chat Box: Spieler reden im Chat mit ihr, sie legt Aufträge an und meldet Ergebnisse.
Die ursprüngliche All-in-one-Turtle mit Claude an Bord gibt es noch als Rolle `turtle` (Altlast).

## Installation

Auf jeder neuen Turtle bzw. jedem neuen Computer:

```
wget run https://raw.githubusercontent.com/Hiabst2/turtle-claude/main/bootstrap.lua
```

Der Bootstrap fragt die Rolle ab und richtet alles ein:

| Rolle | Gerät | Inhalt |
|---|---|---|
| `miner` | Turtle | Worker: holt Aufträge von der Zentrale und arbeitet sie ab; Programme auch von Hand im Terminal |
| `turtle` | Turtle | Claude-Turtle (Altlast): Chat, Mining, Kolonie (fragt API-Key, Besitzer, Name) |
| `gps` | Computer | GPS-Sender (fragt die eigenen Koordinaten) |
| `gateway` | Computer | TurtleMQ-Gateway mit Statusanzeige aller Geräte (Ender Modem, Chunk dauerhaft laden) |
| `central` | Computer | Zentrale mit Job-Dienst: verteilt Aufträge an Miner (Ender Modem, Chunk dauerhaft laden) |
| `command` | Computer | Leitstelle: Claude mit Chat Box, steuert die Turtles über Aufträge (fragt API-Key, Besitzer, Name) |

Später reicht `update`. Es lädt nur die Dateien der eigenen Rolle (`roles/<rolle>.txt`), alle vom
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
| `worker` | Worker-Dienst der Miner (startet automatisch): `P` Pause, `Q` zurück zur Shell |
| `diag [gear\|home\|log]` | Fehlersuche: Ausrüstung, Position und Heimplatz, letzte Meldungen (auch in `diag.txt`) |
| `gateway` | TurtleMQ-Gateway (Rolle `gateway`, startet automatisch) |
| `central` | Zentrale mit Eingabezeile für Aufträge, Zonen und Orte (Rolle `central`, startet automatisch) |
| `command` | Leitstelle mit Claude (Rolle `command`, startet automatisch) |
| `mqtail [topic ...]` | TurtleMQ-Nachrichten live mitlesen, z.B. `mqtail worker.*` |

Die Bibliotheken (z.B. `turtle/nav.lua`, `turtle/mine.lua`) laden die Programme selbst, siehe „Entwicklung“.
Der API-Key liegt nur in den Turtle-Settings, nie im Repo.

## Sicherheit

Jeder Abbau wird in `nav.lua` geprüft, egal ob von Claude, Stripmine oder Heimweg:

- nur mit GPS, nur innerhalb einer Mining-Zone, nie über dem Höhenlimit (Standard Y 50)
- ohne Zone gräbt die Turtle gar nicht
- Truhen, Kolonie-Blöcke, Computer, Türen, Glas, Create-Maschinen usw. nie

Per Chat darf nur der Besitzer (`set claude.owner <Name>`) die Turtle steuern, Fragen darf jeder stellen.
Zonen und Höhenlimit ändert sie per Chat erst, wenn der Besitzer mit „ja“ bestätigt. Im Terminal mit `zone`.

`startup.lua` startet nach jedem Neustart das Programm der eigenen Rolle (`worker`, `central`, `gateway`,
`command`, `claude` oder `gpshost`); unterbrochene Aufträge werden dabei fortgesetzt.
Zustandsdateien (`/.nav`, `/.zones`, `/.job`) werden mit Sicherung gespeichert; ist eine kaputt,
meldet die Turtle das, statt still neu anzufangen.

## Heimplatz-Aufbau

Worker bekommen ihren Heimplatz von der Zentrale (`place home <Name> x y z richtung`), die Claude-Turtle per
`sethome`.

- **unter** der Turtle: Ausrüstungskiste (Toolbox) mit Ender Modem, Spitzhacke, Geo Scanner, Kisten
  (Claude-Turtle zusätzlich Player Detector)
- **neben** der Turtle: Colony Integrator (optional)
- **hinter** der Turtle: Truhe zum Ausladen (nur wenn es keinen eigenen Lagerplatz gibt)
- **über** dem Heimplatz frei bis zur Reisehöhe (Standard Y 110, `set claude.travel_y <y>`)

Worker legen die Spitzhacke selbst an. Das Ender Modem ist fest ausgerüstet oder liegt im Inventar; dann wird es,
wie der Geo Scanner, nur kurz gegen die Spitzhacke getauscht.
Bei der Claude-Turtle bleibt die Chat Box angelegt, Scanner, Detector und Modem ersetzen kurz die Spitzhacke.

## Lagerplatz (optional, `setdepot`)

Eigener Platz zum Ausladen und Tanken, z.B. am Tom's-Storage-Lager:

- **hinter** der Turtle: *Inventory Cable Connector*: alles wird reingeworfen (eigene Kohle bis auf einen Stapel)
- **unter, rechts oder links**: *Filtered Cable Connector* mit Filter Kohle: davon wird nachgetankt (bis 5000, `set claude.fuel_target`)
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
Miner-Turtles melden sich über den Worker-Dienst auch im Leerlauf.

Die Turtle braucht ein Wireless/Ender Modem: fest ausgerüstet oder im Inventar (dann wird es für jeden Sync
kurz statt der Spitzhacke angelegt). Gesynct wird nur an sicheren Stellen: zwischen zwei Mining-Schritten,
unterwegs nach einer Bewegung (höchstens einmal je Intervall), im Leerlauf und am Ende eines Auftrags.
Nachrichten gehen nicht verloren, auch wenn die Turtle länger kein Signal hat; Post vom Gateway holt sie beim
nächsten Sync ab.

## Zentrale und Aufträge (P3)

Die Zentrale (Rolle `central`) verteilt Aufträge an Miner-Turtles. Miner mit TurtleMQ starten den
Worker-Dienst (`worker`) automatisch: Er meldet sich frei, bekommt beim nächsten Sync einen passenden
Auftrag, arbeitet ihn mit den normalen Programmen ab (alle Schutzregeln gelten) und meldet Fortschritt.

Auftrag anlegen in der Eingabezeile der Zentrale, z.B.:

```
add orehunt x=725 y=40 z=630 f=nord rounds=2 area=700,0,600,750,60,650
add tunnel x=710 y=40 z=610 f=sued length=20 width=3 height=3 prio=8
add stonehunt x=725 y=70 z=630 f=nord amount=640 keep=minecraft:cobblestone only=true
list
cancel J3
```

- Zuteilung nach Rolle und Ausrüstung (Erzjagd nur mit Geo Scanner), Priorität vor Alter
- Lease: meldet sich ein Worker 5 Minuten nicht, geht der Auftrag zurück in die Warteschlange;
  kommt der alte Worker zurück, wird er gestoppt
- Aufträge mit überlappendem Bereich (`area`) laufen nie gleichzeitig
- nach 3 Fehlschlägen ist ein Auftrag endgültig gescheitert
- Worker: `P` pausiert (keine neuen Aufträge), `Q` zurück zur Shell
- Behalten wird Beute (Erze, Rohstoffe, Edelsteine, Staub, Kohle; erkannt am Namen oder an den Item-Tags), dazu
  Ausrüstung und Brennstoff. Alles andere wirft die Turtle ab, wenn der Platz knapp wird. Je Auftrag:
  `keep=amethyst,minecraft:dirt` behält zusätzlich, `only=true` behält **nur** `keep`
- `stonehunt`: Stein sammeln. Gang mit Block darüber und darunter, Bahnen hin und her, bis `amount` Items beisammen
  sind (Standard 640 Bruchstein/Bruch-Deepslate, 6 Blöcke unter der Oberfläche oder auf `level`), dann ins Lager
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

Fertige und gescheiterte Aufträge meldet die Leitstelle von selbst im Chat, ohne Claude zu fragen. Claude
wird nur aufgerufen, wenn jemand die Leitstelle beim Namen anspricht. Steuern darf nur der Besitzer,
Fragen darf jeder stellen. Mit Colony Integrator am Computer beantwortet sie auch Fragen zur Kolonie.
Die All-in-one-Turtle (`claude`, Rolle `turtle`) ist Altlast und wird nicht mehr weiterentwickelt.

```
set claude.model claude-opus-5-5   Modell (Standard claude-opus-5-5)
set claude.effort low              Denktiefe low/medium/high (Standard low)
```

Der Verlauf wird nur hinten ergänzt. Nach 20 Einträgen oder 15 Minuten Ruhe beginnt eine neue Sitzung, die mit
einer kurzen Lagemeldung der offenen Aufträge startet (Whitepaper 6.2).

## Entwicklung

Aufbau des Repositorys (auf dem Gerät liegen alle Dateien flach im Hauptverzeichnis, `update` packt sie aus):

| Ordner | Inhalt |
|---|---|
| `/` | `startup`, `update`, `bootstrap` (müssen oben liegen) |
| `core/` | Grundlagen: Speichern, Fuel-Formel, Krypto, Version |
| `turtle/` | Bewegung, Zonen, Ausrüstung, Wegsuche, Mining, Worker-Logik |
| `net/` | TurtleMQ: Nachrichten, Sync-Fenster, Broker |
| `central/` | Dienste der Zentrale: Jobs, Karte, Wege |
| `claude/` | Claude-Agent, Leitstelle, MineColonies |
| `apps/` | Hauptprogramm je Rolle (`worker`, `central`, `gateway`, `command`, `claude`, `gpshost`) |
| `bin/` | Befehle fürs Terminal (`stripmine`, `orehunt`, `gohome`, `zone`, `diag`, …) |
| `roles/` | welche Dateien jede Rolle bekommt |
| `tests/`, `docs/` | Tests ohne Minecraft, Whitepaper, Review, Fortschritt |

- Neue Datei: in den passenden Ordner legen und in `roles/*.txt` eintragen. Dateinamen müssen über alle Ordner
  eindeutig sein, weil sie auf dem Gerät flach landen (prüft ein Test).
- `manifests/` und `files.txt` sind Altlast für ältere `update`-Versionen: Sie holen nur das neue `update` und
  `startup`, beim nächsten Start lädt `startup` dann alles neu.
- Tests ohne Minecraft (braucht Lua 5.2): `sh tests/test.sh`. Auf GitHub laufen sie bei jedem Push automatisch.

## Zwischenkiste

In der Kiste legt die Turtle beim Minen die Ausrüstung ab, die sie gerade nicht braucht (bei `orehunt` bleibt
der Geo Scanner dabei, bei Workern das Modem). Während des Auftrags wird die Kiste nicht angefasst, am Ende holt
die Turtle alles wieder raus und baut sie ab.

- **Worker:** Die Kiste ist Pflicht. Sie kommt an die Oberfläche neben den Einstieg (geht das nicht, unten an den
  Einstieg). Nach einem Abbruch durch die Zentrale holt der Worker sie wieder und fährt heim. Seine Ausrüstung
  behält er, sie wandert nicht in die Toolbox.
- **Von Hand** (`stripmine`, `tunnel`, `orehunt` im Terminal oder über die Claude-Turtle): Liegt eine Kiste im
  Inventar, wird sie unter der Turtle abgestellt. Nach der Heimfahrt kommen Kiste und Ausrüstung zurück in die
  Toolbox. Bei `stop` bleibt die Kiste stehen.
