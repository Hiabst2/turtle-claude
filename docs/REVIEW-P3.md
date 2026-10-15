# Review nach P3.3 – Übergabe

| | |
|---|---|
| Stand | Commit `a1f4e7d` (main, 2026-10-14) |
| Umfang | alle Commits seit `c3b33de` (P0.5 bis P3.3 + Worker-Fixes) |
| Methode | nur Code gelesen. Die Tests (`tests/test.sh`) wurden **nicht** ausgeführt (kein lua5.2 verfügbar). |
| Einbau | nach P3.4 |

**Auftrag an die bearbeitende Instanz:** Jeden Punkt erst selbst prüfen. Die Befunde sind Hypothesen aus dem Lesen. Zu jedem bestätigten Punkt zuerst einen fehlschlagenden Test in `tests/` schreiben, dann fixen. Nicht bestätigte Punkte kurz begründet verwerfen.

Bezüge auf das Whitepaper meinen `docs/WHITEPAPER.md` (liegt im Moment nur lokal, nicht im Repo).

---

## R1 – Lease läuft bei langen Fahrten ab (hoch)

**Wo:** `jobsvc.lua:252` (`M.LEASE = 300`), `jobrunner.lua:274` (Anfahrt), `mine.lua:128` (`unloadAndReturn`), `mine.lua:236` (`finish`)

**Mechanismus:** Die Lease wird nur durch `job.accept`/`job.progress` verlängert, also nur bei einem Sync. Gesynct wird während eines Auftrags nur in `maintain()` (`pcall(sync.maybe)`). Kein Sync gibt es bei:

- `takeFromHome` vor dem Auftrag (Flug heim zur Toolbox)
- `nav.travel` zum Startpunkt
- `unloadAndReturn` (Lager hin und zurück)
- `finish` → `tripDepot` + `unload` + `goHome`. Erst danach meldet `jobrunner` `job.complete`.

Eine Turtle fährt etwa 2,5 Blöcke/s (8 Ticks pro Bewegung). Bei Y −40 und `TRAVEL_Y` 110 kostet allein Hoch und Runter ~300 Blöcke ≈ 120 s. Schon ab ein paar hundert Blöcken Entfernung sind 300 s überschritten.

**Folgen:**

- Ablauf während der Heimfahrt: `tick()` setzt den Job zurück auf `created`. Das spätere `job.complete` wird als „nicht current“ ignoriert, und der **fertige Auftrag wird erneut vergeben**.
- Ablauf beim Ausladen: Der Job wird neu vergeben, die Bereichsreservierung wird frei. Der alte Worker bekommt erst beim nächsten `maintain`-Sync `job.revoke`. Ist das Lager weit weg, passiert das bei jedem Versuch, und nach `MAX_ATTEMPTS` ist der Job `failed`.

**Prüfen:** Test mit `jobsvc` + `jobrunner`, in dem die Heimfahrt in `finish` simulierte Zeit > `LEASE` verbraucht. Erwartung heute: Job wird `created` statt `complete`.

**Fix-Vorschlag:**

- **Variante A:** In `nav.lua` ein optionaler Callback `M.onMove` (in `moved()` aufgerufen, gedrosselt z.B. alle 20 Bewegungen). `jobrunner.init()` setzt ihn auf `function() pcall(sync.maybe) end`. Achtung: `sync` lädt selbst `nav`, deshalb Callback statt `require`. `sync.maybe` tauscht beim Flug das Werkzeug, das ist nach einer erfolgreichen Bewegung unkritisch.
- **Variante B (ergänzend):** Bei `assign` die Lease um die geschätzte Fahrzeit verlängern (`cost.trip`/2,5 s). Das hilft aber nicht beim Ausladen mitten im Auftrag.
- **Empfehlung:** A, optional plus B.

---

## R2 – Abbruch durch die Zentrale lässt Turtle und Zwischenkiste im Stollen (hoch)

**Wo:** `jobrunner.lua:185-191` (`job.cancel`/`job.revoke` → `nav.abort()`), `mine.lua:491` (`if res ~= "abgebrochen" and opts.start then ... tripHome`)

**Mechanismus:** `nav.abort()` erzeugt den Fehler `"abgebrochen"`. `mine.run` behandelt das wie ein Spieler-„stop“: kein `retrieveChest`, kein Heimweg. Die Turtle bleibt unter der Erde, die Zwischenkiste (mit Geo Scanner bei Stripmine/Tunnel) bleibt stehen.

**Folgen:**

- Der nächste Auftrag scheitert in `runJob` an `nav.travel`. Das Aufsteigen über das Höhenlimit oder aus der Zone ist nicht erlaubt („Anfahrt gescheitert“). `goHomeSafe` mit `lastStart`-Ausweg wird dort nicht benutzt.
- Dem Worker fehlt der Geo Scanner. `idleGear` sucht ihn in der Toolbox und findet ihn nicht.
- R1 löst `job.revoke` regelmäßig aus, das verstärkt das Problem.

**Prüfen:** Test „Abbruch mitten im Tunnel“ (existiert: „Worker: Abbruch mitten im Tunnel stoppt sofort“) erweitern. Erwartung heute: Position ≠ Heim, Kiste steht noch, Scanner nicht im Inventar.

**Fix-Vorschlag:**

- Abbruch durch die Zentrale vom Spieler-„stop“ unterscheiden (z.B. `nav.abort("zentrale")` oder ein eigener Fehlertext).
- In `mine.run` für diesen Fall `retrieveChest` und Heimweg ausführen.
- In `runJob` die Anfahrt mit derselben Ausweich-Logik wie `goHomeSafe` versuchen (erst zu `state.lastStart`, dann hoch).

---

## R3 – `store.load` bevorzugt `.bak` vor `.tmp` (mittel)

**Wo:** `store.lua:37-42`

**Mechanismus:** `save` schreibt `.tmp`, verschiebt die alte Datei nach `.bak` und benennt dann `.tmp` um. Stürzt es zwischen den beiden `fs.move` ab, ist `.tmp` der **neue, vollständige** Stand und `.bak` der alte. `load` liest aber `.bak` zuerst. Der Kommentar in der Datei beschreibt den Fall richtig, die Reihenfolge im Code ist falsch.

**Folge:** `/.nav` lädt eine Position, die einen Schritt alt ist. Die Turtle liegt dann einen Block daneben, ohne es zu merken.

**Prüfen:** Test: `.tmp` = neu, `.bak` = alt, Hauptdatei fehlt → `load` muss `neu` liefern.

**Fix:** Erst `.tmp`, dann `.bak` lesen. Ein unvollständiges `.tmp` (Absturz während des Schreibens) liefert `nil` und fällt korrekt auf `.bak` zurück.

**Ergänzend:** Bricht die Turtle zwischen `turtle.forward()` und dem Speichern ab, ist die Position ohnehin um einen Block falsch. Worker haben jetzt ein Modem, also beim Start (oder vor dem Fortsetzen eines Auftrags) die Position per `gps.locate` prüfen und bei Abweichung korrigieren oder melden.

---

## R4 – `bootstrap` bricht bei leerer Eingabe ab (mittel, unbestätigt)

**Wo:** `bootstrap.lua:44` (API-Key), `:46` (Besitzer), `:52` (GPS-Koordinaten)

**Mechanismus:** `ask()` liefert `nil`, wenn man Enter drückt und es keinen Standardwert gibt. `settings.set(name, nil)` wirft in CC:Tweaked vermutlich `bad argument #2`. Bei `gps.*` reicht auch eine Eingabe, die keine Zahl ist (`tonumber`).

**Prüfen:** In CC oder in der Attrappe nachstellen. Wenn die Attrappe `nil` erlaubt, die Attrappe an CC angleichen.

**Fix:** Nachfragen, bis ein gültiger Wert kommt, oder bei `nil` nichts setzen und einen Hinweis ausgeben.

---

## R5 – Leitstelle meldet „fertig“ ohne das Urteil der Zentrale (mittel)

**Wo:** `commander.lua:371` (Abo `job.complete`/`job.fail`), `commander.lua:353-366`

**Mechanismus:** Das Gateway schickt der Leitstelle eine Kopie der **Worker-Nachricht**. Ob die Zentrale sie angenommen hat (Epoche aktuell, Lease gültig), ist dabei nicht bekannt. In Kombination mit R1 steht im Chat „Auftrag fertig“, während der Job in Wahrheit wieder in der Warteschlange liegt. Außerdem werden doppelte Meldungen nach einem Worker-Neustart zweimal angesagt.

**Fix:** Die Zentrale veröffentlicht bei jedem Zustandswechsel `job.state` (`{ id, state, worker, result/reason }`). Die Leitstelle abonniert nur das.

---

## R6 – `job_create` kann doppelte Aufträge erzeugen (mittel)

**Wo:** `commander.lua:439`, `jobsvc.lua:423`

**Mechanismus:** Bei einem Timeout (8 s) sagt das Tool „vielleicht nicht angelegt“. Claude ruft `job_create` dann wahrscheinlich nochmal auf. Das ist eine neue Nachricht mit neuer ID, die MQ-Dedupe greift also nicht.

**Fix:** Die Leitstelle schickt einen `request_id` mit (z.B. die ID der ersten Anfrage). `jobsvc` merkt sich `request_id → job.id` und liefert bei einer Wiederholung den vorhandenen Job zurück.

---

## R7 – `seen`-Liste fest auf 500 IDs (niedrig)

**Wo:** `mq.lua:34` (`SEEN_MAX`), `mq.lua:105-114`

**Mechanismus:** Doppelte werden nur innerhalb der letzten 500 IDs erkannt, die TTL beträgt aber bis zu 3600 s. Am Gateway (Heartbeats aller Geräte) rollt die Liste bei mehr Geräten in weniger als einer Stunde durch. Danach kann ein spät wiederholtes oder abgefangenes und wieder eingespieltes Paket erneut verarbeitet werden.

**Fix:** Zu jeder ID den Ablaufzeitpunkt `ts + ttl` speichern. Eine ID erst nach ihrem Ablauf entfernen. Zusätzlich eine harte Obergrenze als Speicherschutz.

---

## R8 – Gateway liest im Sekundentakt alle Outbox-Dateien (niedrig, Performance)

**Wo:** `broker.lua:404` (`statusLines` → `node:pending(d.id)` pro Gerät), `broker.lua:367` (`snapshot`), `gateway.lua:433`, `mq.lua:88` (`list` lädt jede Datei)

**Fix:** Zählerstand pro Ziel im Speicher führen und bei `send`/`forward`/ACK/`drop` anpassen. Alternativ `list` einmal pro Runde laden und daraus zählen.

---

## R9 – Jobs werden nie aufgeräumt (niedrig)

**Wo:** `jobsvc.lua:276` (`save` schreibt bei jeder Nachricht alle Jobs)

**Fix:** Abgeschlossene Jobs (`complete`/`failed`/`cancelled`) nach z.B. 24 h aus `state.jobs` entfernen, optional in eine begrenzte Archivdatei verschieben.

---

## R10 – Aufträge ohne Zone reservieren keinen Bereich (niedrig)

**Wo:** `jobsvc.lua:346` (`areaFree`: ohne `area` immer frei), `commander.lua:436`

**Folge:** Zwei Aufträge mit x/y/z ohne `zone` am selben Ort laufen gleichzeitig.

**Fix:** Ohne `area` einen Bereich aus Startpunkt und `cost.jobBudget`/Parametern ableiten (z.B. Radius bei Orehunt `rounds × 2 × radius`).

---

## R11 – Modell-ID (offen aus B11)

**Wo:** `claude.lua:24`, `agent.lua:29`, `command.lua:22` – Standard `claude-opus-5`

**Aufgabe:** Gültige ID prüfen und an **einer** Stelle als Standard definieren.

---

## R12 – Whitepaper ins Repo

`mq.lua`, `jobsvc.lua`, `broker.lua`, `mapsvc.lua` und `tests/gateway_tests.lua` verweisen auf Abschnitte des Whitepapers. `docs/WHITEPAPER.md` liegt aber nicht im Repo. Die Datei committen (liegt lokal vor) und an den Stand P3 anpassen. P0.5–P3.3 sind erledigt, die Festlegungen aus dem Code sollten übernommen werden, z.B. `mq.done`, Sync-Modus, `map.*`-Topics, Job-Epoche.

---

## Empfohlene Reihenfolge

1. R3 (klein, eindeutig)
2. R1 + R2 zusammen (hängen zusammen, betreffen dieselben Abläufe)
3. R5, R6
4. R4 (nach Prüfung in CC)
5. R7–R12

Nach jedem Block `tests/test.sh` laufen lassen. R1 und R2 zusätzlich im Spiel mit einem weit entfernten Lager testen.
