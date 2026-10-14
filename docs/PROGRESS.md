# turtle-claude – Fortschritt

Laufendes Protokoll: was gebaut wurde, was entschieden wurde, was offen ist.
Grundlage ist das Whitepaper/Lastenheft „cc:claude v2“ (Draft 0.2). Wird bei jedem Checkpoint aktualisiert.

## Stand

| Phase | Inhalt | Status | Commits |
|---|---|---|---|
| v1 | All-in-one-Turtle mit Claude (Chat, Mining, Kolonie, Zonen, GPS, Lager) | fertig, **Altlast** | bis `c3b33de` |
| P0.5 | Stabilisierung v1 (Bugfixes B1–B12 aus dem Code-Review) | fertig | `1df1cf7`, `b4dce43` |
| P0.6 | Deployment: Rollen-Manifeste, Bootstrap, update vom selben Commit, Kanäle, Version | fertig | `6add39e` |
| P1 | TurtleMQ: Nachrichten mit ACK/Retry/Dedupe, Gateway, Sync-Fenster der Turtle | fertig, im Spiel getestet | `e86467a`, `7de5a93`, `e019aa2`, `7162a2b` |
| P2 | Signatur (HMAC-SHA256), Flottenstatus | fertig | `0a97e89`, `5029822` |
| P3.1 | Zentrale mit Job-Dienst (Leases, Zuteilung, Reservierung), Worker-Dienst für Miner | fertig | `dc524ec` |
| P3.2 | Map-Dienst (Zonen/Orte zentral), Path-Dienst, Fuel-Prüfung | fertig | `8520527` |
| P3.3 | Leitstelle: Claude auf Computer mit Chat Box, steuert über Aufträge | fertig | `ba6575d` |
| P3.4 | Großer Test im Spiel | **läuft** | Fixes ab `73f2f05` |

Tests ohne Minecraft: `sh tests/test.sh` (Lua 5.2, CC-Attrappen, simuliertes Funknetz mit Verlust/Duplikaten).
Szenario-Tests (`Szenario: ...` in `tests/job_tests.lua`): Turtle mit **wirklicher** Position in einer nachgebildeten Welt, echtes GPS, Zentrale, Neustarts und Versetzen – prüfen, wo sie wirklich landet und wo sie unterwegs war.

## Geräte und Rollen

| Rolle | Gerät | Programm | Zweck |
|---|---|---|---|
| `gateway` | Computer + Ender Modem, Chunk dauerhaft geladen | `gateway` | TurtleMQ-Broker, Postfächer, Gerätestatus |
| `central` | Computer + Ender Modem, Chunk dauerhaft geladen | `central` | Job-, Map-, Path-Dienst; Konsole für Aufträge/Zonen/Orte |
| `command` | Computer + Chat Box + Ender Modem | `command` | Leitstelle: Claude im Chat |
| `miner` | Turtle | `worker` | holt Aufträge, arbeitet sie ab |
| `gps` | Computer + Modem | `gpshost` | GPS-Sender |
| `turtle` | Turtle | `claude` | alte All-in-one-Turtle (Altlast, wird abgeschafft) |

## Wichtige Entscheidungen

- **Sicherheit lokal:** Jede Turtle prüft jeden Block selbst (Zonen, Höhenlimit, geschützte Blöcke), auch wenn die Zonen zentral gepflegt werden.
- **Steuern nur der Besitzer**, fragen darf jeder. Zonen/Höhenlimit/Orte per Chat nur nach „ja“ des Besitzers – geprüft im Code, nicht von Claude.
- **TurtleMQ at-least-once:** speichern → ACK → verarbeiten; Doppelte über die id erkannt. ACK pro Strecke (`hop`).
- **Turtles = Sync-Geräte:** Post nur beim Kontakt, Ende mit `mq.done`; keine Funksprüche auf Verdacht.
- **Zentrale** auf eigenem Computer; **All-in-one-Turtle** bekommt keine neuen Funktionen mehr.
- **Worker:** Kiste als Zwischenspeicher ist Pflicht für Mining-Aufträge; was in der Toolbox daheim liegt, zählt als vorhanden; nach jedem Auftrag heim; Einstieg merken; beim Start und alle 10 min GPS-Kontrolle.
- **Commits** nur je Checkpoint.

## Heimplatz-Aufbau eines Workers

- Turtle steht auf dem Heimplatz, **darunter die Toolbox** (Ender Modem, Geo Scanner, Kisten)
- darüber frei bis Reisehöhe Y 110
- Heimplatz an der Zentrale: `place home <Label> <x> <y> <z> <richtung>` (Koordinaten der Turtle, nicht der Kiste; Richtung = wohin sie schaut)
- Lager: `place depot ...` (Connector hinter der Turtle, Kohle-Connector daneben/darunter)

## P3.4 – Erkenntnisse aus dem Spieltest

| Problem | Ursache | Fix |
|---|---|---|
| Worker wartet für immer | nach Auftrag mit Heimfahrt Modem in die Toolbox gelegt | Worker behalten Ausrüstung (`73f2f05`) |
| Kiste soll Pflicht sein | Wunsch | Mining-Aufträge nur mit Kiste (`73f2f05`) |
| fest ausgerüstetes Modem galt als fehlend | Prüfung nur im Inventar | `gear.has` (`277699a`) |
| Turtle wartet, Auftrag bleibt `created` | Grund unsichtbar; Fuel > 1000 aber zu wenig | `job.none` mit Grund, Tanken nach Bedarf (`ed5725f`) |
| Ausrüstung liegt daheim, Turtle woanders | galt als nicht brauchbar | Toolbox zählt, Umweg im Fuel (`e89d299`) |
| veraltetes Wissen über die Toolbox | — | Status-Zeile, Nachschauen bei „fehlt“ (`ec12e01`) |
| Turtle steckt nach Tunnel unter der Erde | Tunnel fuhr nicht heim, Einstieg unbekannt | heimfahren, Einstieg merken, letzte Meldung (`a1f4e7d`) |
| Turtle fährt in die falsche Richtung | Position/Blickrichtung verloren (z.B. versetzt) | GPS-Einmessen beim Start + Kontrolle, Orte nur mit GPS (`e1eed33`) |
| „Heimweg gescheitert: über dem Höhenlimit“, obwohl oben frei | kurze Wege (< 9 Blöcke) fuhren direkt seitwärts und wollten durch eine Wand graben | versperrter kurzer Weg → über die Reisehöhe; Meldung nennt Ort und Block (`3f5dd04`) |
| Heimplatz = Stelle, an der die Turtle hingestellt wurde | Platzhalter-Heimplatz einer neuen Turtle wurde beim GPS-Einmessen zu Weltkoordinaten; Orte der Zentrale bei gleichem Kartenstand nicht neu übernommen | Heimplatz gilt erst nach sethome/place home; Einmessen rechnet nur gesetzte um; Worker holt Orte beim Start frisch (`587ac8e`) |
| Heimplatz 30 Blöcke unter dem Start | Turtle mit GPS wurde versetzt; beim Einmessen wurde der schon absolute Heimplatz um die Versatz-Strecke mitverschoben | Heim-/Lagerplatz nur beim ersten Einmessen (vorher relativ) umrechnen (`cfe1c88`) |
| derselbe Fehler nach dem Fix | falscher Heimplatz stand noch in der Turtle; beim Start flog sie dorthin, **bevor** der richtige von der Zentrale ankam. Neue Turtle: Heimplatz kam spaeter, nächster Versuch erst nach 10 min | erst Karte holen (`full`, auch bei Stand 0), dann fahren; neuer Heimplatz → sofort hin und Toolbox neu anschauen. Szenario-Tests mit nachgebildeter Welt (`18348a1`) |
| immer noch: Heimplatz = Standort | **noch unklar** – Raten beendet | Heimplatz merkt sich seine Herkunft (`[von: ...]`), Protokoll `/.homelog`, Programm `diag`, an der Zentrale `place list` mit Koordinaten (dieser Checkpoint) |

## Offen / Nächste Schritte

- P3.4 abschließen: Miner holt Ausrüstung, nimmt J1 (Erzjagd) an, arbeitet, lädt aus, meldet fertig
- danach laut Roadmap: P4 Scout-System, P5 WorldMap, P6/P7 Server + PostgreSQL, …
- All-in-one-Turtle (`claude.lua`, Rolle `turtle`) entfernen, sobald nicht mehr gebraucht
