# cc:claude v2 – Whitepaper / Lastenheft

| | |
|---|---|
| Version | 0.2 Draft |
| Stand | 2026-10-13 |
| Basis | Draft 0.1 (Zielvision, Roadmap) + Code-Review von v1 |
| Subprojekte | TurtleMQ, WorldMap, Worker Framework, JobNode, PathNode, MapNode, GatewayNode |

Änderungen gegenüber 0.1 sind mit **(neu)** markiert. Eine Zusammenfassung steht in [Abschnitt 16](#16-änderungen-gegenüber-draft-01).

---

## 1. Vision

**Ursprünglich:** Integration eines LLM (Claude) in CC:Tweaked Turtles.

**Jetzt:** Ein verteiltes Agentensystem für ComputerCraft.

```
Claude (eine zentrale Instanz)
  ↓
Services (Command, Job, Path, Map, Gateway)
  ↓
Worker-Turtles (Miner, Scout, Builder, Courier)
  ↓
Minecraft-Welt
```

Das System soll

- autonom Aufgaben ausführen,
- Weltwissen sammeln und teilen,
- Jobs koordinieren,
- später selbst Fehler analysieren.

**Abgrenzung (neu):** Worker haben keinen API-Key und kein LLM. Sie arbeiten Jobs deterministisch ab. Claude läuft genau einmal, im Command Node.

---

## 2. Designprinzipien

| Prinzip | Bedeutung |
|---|---|
| Serviceorientiert | Spezialisierte Rollen statt einer Turtle, die alles macht |
| Lose Kopplung | Kommunikation ausschließlich über TurtleMQ, keine direkten Aufrufe zwischen Komponenten |
| Persistenz | Jeder kritische Zustand übersteht Neustart, Chunk-Unload und Absturz |
| Offlinefähigkeit | Turtles arbeiten zeitweise ohne Verbindung (Store-and-Forward) |
| Eventual Consistency | Echtzeit ist nicht nötig, Datenverlust ist nicht erlaubt |
| **Idempotenz (neu)** | Jede Nachricht darf mehrfach ankommen, ohne dass etwas doppelt passiert (Folge von ACK + Retry) |
| **Sicherheit lokal (neu)** | Zonen, Höhenlimit, geschützte Blöcke und Not-Aus werden immer lokal geprüft, nie nur zentral |
| **Atomare Schreibvorgänge (neu)** | Zustandsdateien werden nie direkt überschrieben (`.tmp` schreiben, dann `fs.move`) |

---

## 3. Systemübersicht

```
cc:claude
├─ Command Node     Claude, Tool Calling, Chat Box, Benutzerkommunikation
├─ Gateway Node     TurtleMQ-Broker, Postfächer, Discovery, Bridge zum Server
├─ Job Node         Aufträge, Prioritäten, Zuweisung, Leases
├─ Path Node        Routen, A*, Wegkosten
├─ Map Node         Scans, Weltmodell
│
├─ Miner / Scout / Builder / Courier / Rescue (neu)
│
├─ Externer Server  API, PostgreSQL, Website
└─ Website          Leitstand, Karte
```

Die Chat Box sitzt nur am Command Node (Main Controller). Gateway, Job, Path und Map können anfangs auf demselben CC-Computer laufen und werden später ausgelagert. Wichtig ist nur, dass sie ausschließlich über TurtleMQ miteinander reden.

**Gateway = Broker (neu, Festlegung):** Der Gateway Node ist die Broker-Zentrale. Er läuft dauerhaft in einem dauerhaft geladenen Chunk und hält ein Postfach pro Empfänger.

---

## 4. TurtleMQ

### 4.1 Ziel

Robustes Nachrichtenprotokoll mit Persistenz, ACK, Retry und Store-and-Forward. Eigene Implementierung, Transport über Modem (`modem.transmit`/`rednet`), keine Abhängigkeit von `rednet.host`.

### 4.2 Zustellgarantie (neu)

**At-least-once.** Eine Nachricht geht nie verloren, kann aber doppelt ankommen. Doppelte werden beim Empfänger über die `id` erkannt (siehe 4.6). Exactly-once wird nicht versprochen, sondern durch Dedupe und idempotente Handler erreicht.

### 4.3 Nachrichtenformat

```lua
{
  v = 1,                         -- (neu) Protokollversion
  id = "12:1760352000123:7",     -- <computerID>:<os.epoch("utc")>:<Zaehler>
  ts = 1760352000123,            -- Erzeugungszeit (ms, UTC)
  source = 12,                   -- Computer-ID
  target = "gateway" | 17 | "*", -- Ziel: Dienst, Computer-ID oder Broadcast
  topic = "job.assign",
  payload = { ... },
  ttl = 3600,                    -- (neu) Sekunden; danach verwerfen statt zustellen
  reply_to = nil,                -- (neu) id der Anfrage, z.B. bei path.response
  attempt = 1,                   -- (neu) Sendeversuch, nur zur Diagnose
  sig = nil,                     -- (neu) HMAC, ab Phase "Security" Pflicht
}
```

Große Payloads (Scans) werden in Teilnachrichten mit `part`/`parts` zerlegt, Richtwert ≤ 16 KB pro Nachricht **(neu)**.

### 4.4 Topics

```
worker.register    worker.heartbeat   worker.status   worker.error
job.create  job.assign  job.accept (neu)  job.progress (neu)  job.complete  job.fail (neu)  job.lease (neu)
map.scan    map.update
path.request       path.response
system.discovery   system.update (neu, Hinweis auf neue Version)
mq.ack (neu)
```

Publish/Subscribe läuft über den Broker: Dienste melden ihre Topics beim Gateway an, und der Gateway verteilt eingehende Nachrichten in die Postfächer der Abonnenten.

### 4.5 Persistenz

```
/.mq/
  outbox/<id>     noch nicht bestaetigt gesendet
  inbox/<id>      empfangen, noch nicht verarbeitet
  seen            Ringpuffer der zuletzt verarbeiteten ids (Dedupe), z.B. 500 Eintraege
  archive/        optional, begrenzt (max. N Dateien oder X KB), aeltestes zuerst loeschen
```

`pending/` aus Draft 0.1 entfällt **(neu)**. „Gesendet, ACK steht aus“ ist einfach eine Datei in `outbox/` mit gesetztem Versuchszähler. Jede Datei wird atomar geschrieben (`.tmp`, dann `fs.move`).

### 4.6 Ablauf

**Sender:**
```
SEND → in outbox/ speichern → senden → auf mq.ack warten (Timeout 2 s)
     → ACK: Datei loeschen
     → kein ACK: im naechsten Sync-Fenster erneut (Backoff), nach ttl verwerfen + worker.error
```

**Empfänger:**
```
empfangen → id in seen? → ja: nur ACK senden, nicht verarbeiten
                        → nein: in inbox/ speichern → ACK senden → verarbeiten → id in seen → Datei loeschen
```

Das ACK geht erst raus, wenn die Nachricht persistiert ist. Ein Absturz zwischen Speichern und Verarbeiten führt dann nur zu erneuter Verarbeitung aus `inbox/`, nicht zu Verlust.

### 4.7 Store-and-Forward und Sync-Fenster

Turtles ohne dauerhaftes Modem (Scouts) arbeiten mit Sync-Fenstern:

```
Modem einwechseln → outbox abarbeiten → Postfach beim Gateway abholen → Modem auswechseln
```

- Sync-Intervall Standard 60 s (konfigurierbar), zusätzlich bei Job-Ende und bei Fehlern.
- Ein Sync zählt gleichzeitig als Heartbeat.

---

## 5. Worker Framework

### 5.1 Gemeinsamer Kern

Jeder Worker hat dieselbe Basis:

- MQ-Client (4.)
- Navigation mit lokaler Sicherheitsprüfung (Zonen, Höhenlimit, geschützte Blöcke) – übernommen aus v1 `nav.lua`/`zones.lua`
- Job-Runner mit Persistenz und Resume – übernommen aus v1 `mine.lua` (`/.job`)
- Hardware-Manager (Upgrade tauschen) – übernommen aus v1 `gear.lua`

### 5.2 Rollen

| Rolle | Aufgaben | Hardware (fest + Wechsel) |
|---|---|---|
| Miner | Abbau, Ore Hunt, Tunnel, Strip Mine | Spitzhacke + Modem; Geo Scanner optional im Wechsel mit dem Modem |
| Scout | Kartierung, Erkundung, POIs | Chunky fest; Geo Scanner und Modem im Wechsel, Store-and-Forward |
| Builder | Bauprojekte, Wartung, Infrastruktur | offen |
| Courier | Transport | offen |
| **Rescue (neu)** | liegengebliebene Turtles bergen (Fuel bringen, abholen) | Spitzhacke + Modem |

### 5.3 Worker-Zustände (neu)

Bei 60 s Sync-Intervall:

| Zustand | Bedingung |
|---|---|
| online | letzter Kontakt < 1,5 × Intervall |
| overdue | > 3 × Intervall ohne Kontakt |
| lost | > 10 × Intervall ohne Kontakt → Incident, ggf. Rescue-Job |

Scouts melden vor dem Abtauchen ihre erwartete Offline-Dauer. Solange die nicht überschritten ist, gelten sie nicht als overdue.

---

## 6. Computerzentrale

| Node | Verantwortung | Nicht zuständig |
|---|---|---|
| Command | Claude, Tool Calling, Chat Box, Benutzer | keine direkte Hardwaresteuerung |
| Gateway | Broker, Postfächer, Discovery, Routing, Server-Bridge | keine Fachlogik |
| Job | Aufträge, Prioritäten, Zuweisung, **Leases (neu)** | keine Routen |
| Path | Routen, A*, Wegkosten | kein Kartenspeicher (liest vom Map Node) |
| Map | Scans, Weltmodell, Kartenspeicherung | keine Routen |

### 6.1 Job-Leases (neu)

- Ein Job ist einem Worker nur auf Zeit zugewiesen (Lease, z.B. 5 × Sync-Intervall).
- Der Worker verlängert die Lease mit jedem Heartbeat und `job.progress`.
- Läuft die Lease ab, geht der Job zurück in die Warteschlange.
- Bereiche (Zonen-Ausschnitte) werden pro Job reserviert, damit zwei Miner nie denselben Bereich abbauen.
- Job-Zustände: `created → assigned → accepted → running → complete | failed | expired`.

---

## 7. WorldMap

### 7.1 Grundidee

Die Karte bildet nicht die Minecraft-Welt ab, sondern das **bekannte Wissen** darüber. Nicht gescannte Blöcke existieren für das System nicht (Unknown).

### 7.2 Datenquellen

Geo Scanner, Movement, Inspect, Dig, Place.

### 7.3 Datensatz pro Block (neu)

```
x, y, z, dim, kind (air|ore|solid|fluid|blocked|unknown), name, observed_at, observed_by, source
```

### 7.4 Konsistenz

Problem: Turtle A sieht Luft, Turtle B sieht Stein, ein Spieler hat inzwischen gebaut.

Regel:

1. Lokale Sensorik gewinnt **im Moment der Bewegung**. Die Turtle handelt nach dem, was `inspect`/`detect` gerade liefert, nie nach der Karte.
2. In der Datenbank gewinnt die **jüngste Beobachtung** (`observed_at`) **(neu, präzisiert)**.
3. Abweichungen zwischen Karte und Sensorik werden als `map.update` zurückgemeldet.

### 7.5 Speicher (neu)

Ein Scan mit Radius 8 liefert rund 2000 Blöcke, CC-Computer haben standardmäßig etwa 1 MB Speicher. Die WorldMap auf CC ist daher nur für Tests gedacht. Der dauerhafte Speicher ist der externe Server (Abschnitt 10). Auf den Turtles liegt nur ein lokaler Ausschnitt rund um den aktuellen Job.

---

## 8. Pathing

### 8.1 Ziel

Zentrale Routenplanung im Path Node. Die Turtle plant bei Hindernissen lokal neu (v1 `path.lua` bleibt als Fallback).

### 8.2 Wegkosten

| Zelle | Kosten |
|---|---|
| Tunnel (eigener Gang) | 1 |
| Bekannte Luft | 1 |
| Höhle | 2 |
| Erz | 4 |
| Stein | 10 |
| Deepslate | 14 |
| Unknown | 25 |
| Wasser | 50 |
| Lava | unpassierbar |
| geschützte Blöcke, außerhalb der Zone, über Höhenlimit | unpassierbar |

Hinweise **(neu)**:

- Die kleinsten Kosten sind 1, daher bleibt die Manhattan-Distanz eine zulässige Heuristik für A*.
- Unknown (25) ist teurer als Stein (10). Bekannter Stein wird also lieber gegraben als unbekanntes Gelände betreten. Das ist gewollt.
- Fuel-Kosten einer Route sind die Anzahl Schritte, nicht die Wegkosten. Die Route liefert beides zurück.

### 8.3 Ablauf

```
path.request { from, to, max_cost?, avoid? } → Path Node → path.response { steps[], fuel, cost, map_version }
```

Die Route ist eine Empfehlung. Die Turtle prüft jeden Schritt lokal und meldet Abweichungen.

---

## 9. Website

**Dashboard:** Turtles, Fuel, Status (5.3), Jobs, Logs.

**Karte:** BlueMap-ähnliches Bedienkonzept, aber auf Basis der Scandaten, nicht der Minecraft-Welt.

**Ebenen:** Turtles, Routen (geplant gestrichelt, gefahren durchgezogen), Jobs, POIs, Tunnel, Gefahren, Fog of War.

### 9.1 Monitore im Spiel (Idee)

Ein Leitstand direkt in der Welt, ohne Website: CC-Monitore an Gateway und Zentrale zeigen dieselben Bildschirme
wie das Terminal, nur größer. Noch nicht umgesetzt.

**Hardware**

- **Monitor** (Graustufen) oder **Advanced Monitor** (Farben, Berührung). Nebeneinander gesetzte Blöcke werden
  zu einem Bildschirm, bis 8 breit und 6 hoch.
- Anschluss direkt am Computer (Peripheral-Name `top`, `left` …) oder über **Wired Modem und Netzwerkkabel**
  (`monitor_0` …). So hängt die Anzeige an der Wand, der Computer steht woanders.
- Größe in Zeichen bei Textgröße 1 ungefähr: 1 Block ≈ 7×5, 4×3 Blöcke ≈ 39×19, 8×6 Blöcke ≈ 82×40.
  `setTextScale(0.5)` verdoppelt den Platz, größere Werte (bis 5) sind aus der Entfernung lesbar.

**Software**

Die Zeichenfunktionen `Broker:draw` (Gateway) und `jobrunner.draw` (Worker) benutzen `term` und richten sich nach
`term.getSize()`; Umbruch und Kürzen erledigt `core/text.lua`. Mit `term.redirect` laufen sie unverändert auf
einem Monitor und zeigen dort automatisch mehr (ganze Zeilen, mehr Geräte):

```lua
local mon = peripheral.find("monitor")
if mon then
  mon.setTextScale(0.5)
  local old = term.redirect(mon)
  b:draw(channel)
  term.redirect(old)
end
```

Terminal und Monitor können gleichzeitig laufen: erst normal zeichnen, dann per `redirect` auf den Monitor.

**Anzeigen**

| Wo | Inhalt |
|---|---|
| Gateway | Flottenstatus an der Wand, Farbe nach Zustand (online grün, overdue gelb, lost rot) |
| Zentrale | Auftragstafel: offene, laufende, fertige Jobs mit Worker und Fortschritt |
| später, mit P9 | Fog-of-War-Karte als grobe Pixelfläche (`paintutils`, `blit`) |
| Advanced Monitor | Antippen (`monitor_touch`): Job auswählen, Details zeigen, abbrechen |

Turtles bekommen keine Monitore: Ein Monitor muss fest stehen, die Turtle fährt weg.

**Regeln**

- Einstellungen statt fest verdrahtet: `screen.monitor` (Peripheral-Name, leer = erster gefundener) und
  `screen.scale` (Textgröße).
- Farben nur auf Advanced Monitoren (`isColor()` prüfen), sonst Graustufen.
- `monitor_resize` und `peripheral_detach` behandeln: neu zeichnen bzw. Monitor neu suchen, nie abstürzen.
- Der Monitor steht im selben dauerhaft geladenen Bereich wie Gateway bzw. Zentrale.
- Der Bildschirm-Test (`tests/screen.lua`) prüft zusätzlich typische Monitorgrößen, z.B. 2×2 Blöcke und 8×6 bei
  Textgröße 0.5.

**Aufwand:** klein für Gateway und Zentrale, weil die Zeichenfunktionen schon größenunabhängig sind. Kann
jederzeit nach P3 als eigener Strang gebaut werden.

---

## 10. Datenbank

Externer Server mit PostgreSQL.

| Tabelle | Inhalt |
|---|---|
| turtles | id, label, role, version, channel, last_seen, fuel, position |
| jobs | id, type, state, worker, lease_until, area, payload, result |
| map | x, y, z, dim, kind, name, observed_at, observed_by |
| routes | id, job, planned, driven |
| incidents | id, worker, type, count, first_seen, last_seen, sample |
| **messages (neu)** | Audit-Log des Gateways (begrenzt) |

---

## 11. Deployment

| Thema | Festlegung |
|---|---|
| Source of Truth | öffentliches GitHub-Repository |
| Bootstrap | `wget run <raw-url>/bootstrap.lua` |
| Setup | interaktiver Installer (Rolle wählen), erzeugt die Konfiguration |
| Kanäle | `stable` / `beta` / `dev` = Git-Branches; die Turtle lädt vom Branch ihres Kanals |

Ergänzungen **(neu)**:

- **Manifest pro Rolle** statt einer globalen `files.txt`: ein Miner lädt keinen Code des Path Nodes.
- **Atomares Update:** erst alle Dateien in ein temporäres Verzeichnis laden, nur bei vollständigem Erfolg austauschen. Ein abgebrochenes Update hinterlässt nie eine Mischversion.
- **Version melden:** jeder Worker schickt seine Version im Heartbeat. Das ist die Grundlage für Canary (P20), das damit schon ab P0.6 in einfacher Form möglich ist.
- **Konfiguration:** `config.json` oder CC-`settings`. Geheimnisse (API-Key, MQ-Secret) liegen nur in den Settings, nie im Repository.

---

## 12. Sicherheit (neu)

| Thema | Maßnahme | Wann |
|---|---|---|
| Graben | Zonen, Höhenlimit, geschützte Blöcke lokal in `nav.dig` (wie v1) | sofort |
| Chat-Befehle | OWNER-Checks für alle zustandsändernden Tools (siehe B3) | P0.5 |
| Nachrichten | HMAC-Signatur (`sig`) mit gemeinsamem Secret aus den Settings; unsignierte Nachrichten verwerfen | spätestens P2 |
| Replay | `id` + `ts` + Dedupe-Puffer; Nachrichten älter als `ttl` verwerfen | mit Signatur |
| Reaktor | Not-Aus rein lokal, ohne Netz- oder Claude-Abhängigkeit | P13 |

Derzeit nur eigener Server ohne fremde Spieler. Die Signatur ist deshalb nicht dringend, gehört aber ins Protokoll (`sig`-Feld ab v1), damit später nichts umgebaut werden muss.

---

## 13. Bekannte Probleme

### Slotkonflikte

Ein Scout braucht Geo Scanner, Chunky und Modem, hat aber nur zwei Plätze.

**Lösung:** Chunky bleibt fest, Geo Scanner und Modem wechseln sich ab. Kommunikation per Store-and-Forward (4.7).

### Kartenkonsistenz

Siehe 7.4.

### Chunkloading

- Die Chunky Turtle ist derzeit die wichtigste bekannte Lösung.
- FTB Chunks ist im Modpack vorhanden, eine automatische Integration mit Turtles ist nicht bekannt.
- Der Gateway Node muss in einem dauerhaft geladenen Chunk stehen.
- **(neu)** Eine Turtle in einem entladenen Chunk ist eingefroren. Store-and-Forward sorgt nur dafür, dass Nachrichten an sie nicht verloren gehen. Die Statuslogik (5.3) muss das berücksichtigen.

---

## 14. Stabilisierung v1 (P0.5) – Bugfix-Liste

Ergebnis des Code-Reviews von v1 (Stand Commit `c3b33de`). Pfade relativ zum Repository.

| # | Prio | Problem | Ort | Fix |
|---|---|---|---|---|
| B1 | hoch | Wirft ein Tool einen Lua-Fehler, bleibt im Verlauf ein `tool_use` ohne `tool_result`. Danach lehnt die API jeden Aufruf ab, bis die Turtle neu startet. Beispiel: `comeToPlayer` mit Detector-Antwort ohne `x`. | `claude.lua:617` | `runTool` in `pcall` ausführen, bei Fehler den Fehlertext als `tool_result` (`is_error = true`) zurückgeben. Zusätzlich in `handle` sicherstellen, dass jedes `tool_use` ein Ergebnis bekommt. |
| B2 | hoch | Die Fuel-Reserve rechnet den Weg zum Lager als Manhattan-Distanz. `nav.travel` fliegt aber auf Reisehöhe (Y 110) hoch und wieder runter. Bei tiefen Minen fehlen 100–200 Fuel → Turtle bleibt liegen. | `mine.lua:138` | `nav.tripCost(from, to)` einführen, das dieselbe Logik wie `travel` nachrechnet (Steigung bis `max(TRAVEL_Y, y)`, horizontal, Abstieg). In `maintain` verwenden. |
| B3 | hoch | Per Chat sind nur Zonen abgesichert. `set_home`, `set_depot`, `config set`, `gear take/store`, `gps_locate`, `turtle_do` (drop, place, dig) kann jeder Spieler auslösen. | `claude.lua:540ff` | Gemeinsame Funktion `requireOwner(user)` für alle zustandsändernden Tools; lesende Tools (`status`, `zones list`, `config get`, `colony`) bleiben offen. |
| B4 | hoch | Zustandsdateien werden direkt überschrieben. Bricht der Schreibvorgang ab, liefert `unserialize` `nil` und `nav.lua` setzt Position und Heimplatz stillschweigend auf 0,0,0 zurück. | `nav.lua:24-38`, `zones.lua:14-28`, `mine.lua:157` | Gemeinsames `store.save(path, tbl)`: in `path..".tmp"` schreiben, alte Datei nach `.bak` verschieben, `.tmp` umbenennen. Beim Laden auf `.bak` zurückfallen. Bei `nil` nie still neu initialisieren, sondern melden. |
| B5 | mittel | Orehunt markiert einen Scan-Bereich als erledigt, bevor er erreicht ist. Nach einem Neustart unterwegs wird er übersprungen, und beim Fortsetzen zählen unerreichbare Bereiche als erledigt. | `mine.lua:447` | Zwei Listen: `opts.scanned` (erst nach `scanArea` setzen) und `opts.unreachable` (nach fehlgeschlagenem `path.go`). `nextCenter` überspringt beide, `done` zählt nur `scanned`. |
| B6 | mittel | Chat-Ausgaben werden nach 240 Bytes geschnitten. Das kann ein UTF-8-Zeichen zerteilen und ist mitten im Wort. | `claude.lua:407` | Am letzten Leerzeichen vor der Grenze schneiden, nie innerhalb einer UTF-8-Sequenz (Folgebytes `0x80–0xBF`). |
| B7 | mittel | Kein Retry bei API-Fehlern. 429 oder 529 (überlastet) führen sofort zu „API-Fehler“. | `claude.lua:600` | Bis zu 3 Versuche mit Backoff (2 s, 5 s, 10 s) bei 429, 500, 529 und Timeout; bei 400 nicht wiederholen. |
| B8 | mittel | `update` schreibt Datei für Datei. Bricht ein Download ab, hat die Turtle eine Mischversion. | `update.lua` | Erst alles nach `/.update/` laden, nur bei vollständigem Erfolg verschieben. Gleichzeitig Kanal-Unterstützung (`set claude.channel beta` → Branch). |
| B9 | niedrig | `path.nextOre` durchsucht den gesamten bisher bekannten Bereich. Nach vielen Runden wird das auf CC langsam. | `path.lua:221` | Suchbereich auf Umgebung des aktuellen Scans begrenzen (z.B. Radius + 4) oder Suchschritte deckeln. |
| B10 | niedrig | Chat-Trigger prüft nur den Anfang: „Hiabstxyz, …“ spricht die Turtle ebenfalls an. | `claude.lua:698` | Nach dem Namen ein Trennzeichen oder Zeilenende verlangen. |
| B11 | niedrig | Standard-Modell `claude-opus-5` – Gültigkeit der ID prüfen. | `claude.lua:22` | Gültige ID eintragen bzw. in die Konfiguration verschieben. |
| B12 | niedrig | README: Ausrüstungskiste, Colony Integrator und Reisehöhe stehen unter „Lagerplatz“, gehören laut Code zum Heimplatz. | `README.md` | Abschnitte korrigieren. |

Hinweis: In v2 wandert die Chat Box an den Command Node, und Claude läuft nicht mehr auf der Turtle. B1, B3, B6, B7, B10 und B11 betreffen dann den Command Node, nicht die Worker. Die Fixes lohnen sich trotzdem jetzt, weil v1 bis zur Umstellung produktiv läuft und der Code als Basis für den Command Node dient.

---

## 15. Roadmap

| Phase | Inhalt | Abhängig von |
|---|---|---|
| **P0.5** | Stabilisierung v1 (Abschnitt 14) | – |
| **P0.6** | Deployment Framework: Bootstrap, Rollen-Manifest, Kanäle, atomares Update, Version im Status | P0.5 |
| **P1** | TurtleMQ: Format, Outbox/Inbox, ACK, Retry, Dedupe, Gateway mit Postfächern, Sync-Fenster | P0.6 |
| **P2** | Multi-Turtle: Registrierung, Heartbeats, Zustände, Rollen, **Signatur** | P1 |
| **P3** | Computerzentrale: Command/Job/Path/Map als getrennte Dienste über MQ, **Leases** | P2 |
| P4 | Scout-System: Chunky fest, Scanner/Modem im Wechsel, Store-and-Forward | P1, P3 |
| P5 | WorldMap V1 (auf CC, Testbetrieb) | P4 |
| P6 | Externe API, Gateway-Bridge zum Server | P1 |
| P7 | PostgreSQL | P6 |
| P8 | Dashboard | P7 |
| P9 | Karte (Fog of War) | P7 |
| P10 | Pathing-Orchestrator | P5 oder P7 |
| P11 | Routing Overlay | P9, P10 |
| P12 | Semantische Weltkarte (Tunnel, Höhlen, POIs) | P9 |
| P13 | Reactor Node (eigenständig, Not-Aus lokal) | P1 (nur für Telemetrie) |
| P14 | Storage Node | P1 |
| P15 | Colony Node (aus v1 `colony.lua`) | P1 |
| P16 | Multi-Agent-Orchestrierung | P3, P14 |
| P17 | 3D-Karte | P9 |
| P18 | Incident System | P7 |
| P19 | Claude Developer (kein Auto-Deployment) | P18 |
| P20 | Canary Rollouts (vollständig) | P0.6, P2 |

**Neu:** Rescue-Rolle frühestens nach P3. P13 kann jederzeit als eigener Strang gebaut werden.

**Idee:** Monitore im Spiel (Abschnitt 9.1) für Gateway und Zentrale, jederzeit nach P3 als eigener Strang.

---

## 16. Änderungen gegenüber Draft 0.1

1. Zustellgarantie at-least-once mit Dedupe und idempotenten Handlern (2, 4.2, 4.6).
2. Nachrichtenformat ergänzt: `v`, `ttl`, `reply_to`, `attempt`, `sig`; Zerlegung großer Payloads (4.3).
3. Topics ergänzt: `worker.register`, `job.accept/progress/fail/lease`, `system.update`, `mq.ack` (4.4).
4. `pending/` entfällt, `seen`-Puffer ergänzt, Archiv begrenzt (4.5).
5. Gateway Node als Broker festgelegt (3).
6. Worker-Zustände online/overdue/lost und Job-Leases (5.3, 6.1).
7. Rescue-Rolle (5.2).
8. Kartenkonsistenz präzisiert: jüngste Beobachtung gewinnt in der Datenbank (7.4).
9. Deployment: Rollen-Manifest, atomares Update, Version im Heartbeat (11).
10. Sicherheitsabschnitt (12).
11. Bugfix-Liste v1 (14).
12. Roadmap mit Abhängigkeiten (15).

---

## 17. Offene Fragen

1. **Wo läuft der Path Node langfristig?** A* über große Karten ist auf CC langsam. Vorschlag: auf CC bis P5, danach auf dem Server.
2. **Wie kommuniziert der Gateway mit dem Server?** HTTP-Polling oder WebSocket (CC unterstützt beides). Empfehlung: WebSocket.
3. **Mehrere Dimensionen?** Das Feld `dim` ist in der Karte vorgesehen. Sollen Worker dimensionsübergreifend arbeiten (Ender Modem reicht über Dimensionen)?
4. **Welche Rechte hat Claude im Command Node?** Darf Claude Jobs ohne Bestätigung anlegen, Zonen nur mit Bestätigung (wie v1)?
5. **Teststrategie:** Reine Logik (MQ, Pathing, Zonen) mit plain Lua und Stubs außerhalb von Minecraft testen? Turtle-spezifisches nur im Spiel.
6. **Konfiguration:** `config.json` oder CC-`settings` – eins davon als Standard festlegen.
