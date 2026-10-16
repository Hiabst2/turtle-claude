# Plan: Ausrüstung der Miner (Chunky, Barrel als Zwischenlager)

| | |
|---|---|
| Stand | 2026-10-16, noch nichts davon umgesetzt |
| Grundlage | Gespräch nach dem Spieltest Erzjagd (Review R14–R19), Whitepaper 5.2 und 6.3 |
| Voraussetzung | Branch `test-wegkosten` (R14, R15, R17, `stonehunt`) ist im Spiel getestet und auf `main` |
| Umsetzung | offen, ob durch diese oder die andere Claude-Instanz |

Ziel: Ein Worker fährt pro Auftrag im Idealfall nur noch **einmal** zum Lager, am Ende, und friert unterwegs nie in
einem ungeladenen Chunk ein.

---

## A. Chunky fest, Spitzhacke im Wechsel mit Modem und Geo Scanner

**Ausrüstung eines Miners:**

| Seite | Teil | Wann |
|---|---|---|
| A | Chunky (Advanced Peripherals, Chunky-Turtle-Upgrade) | immer, wird nie getauscht |
| B | Spitzhacke | Normalzustand, zum Graben |
| B, kurz | Wireless/Ender Modem (liegt im Inventar) | nur für den Sync, etwa einmal pro Minute |
| B, kurz | Geo Scanner (liegt im Inventar) | nur für einen Scan |

**Warum:** Der Chunky hält den Chunk geladen, in dem die Turtle gerade ist, beim Minen, bei Fahrten und auf dem
Heimweg. Ein platzierter Chunkloader-Block wäre schlechter: er lädt nur 1 oder 3×3 Chunks, eine Erzjagd geht darüber
hinaus, und bei jeder Lagerfahrt friert die Turtle ein, sobald sie den Bereich verlässt. Ein Chunkloader-Block ist im
Modpack (MineColonies – Create & Conquer) ohnehin nicht nachgewiesen; FTB Chunks lädt nur von Hand.

**Heartbeats:** ändern sich praktisch nicht. Turtles sind schon heute Sync-Geräte (`mode = "sync"`): an sicheren
Stellen prüft `sync.maybe`, ob das Intervall um ist, tauscht dann das Modem kurz ein (`gear.with`, je 1 Tick hin und
zurück), sendet und holt Post, tauscht zurück. Pro Sync etwa 0,1 s mehr als mit festem Modem. Nachrichten an die
Turtle (auch Abbruch) kommen wie bisher beim nächsten Sync an, also mit bis zu einer Minute Verzögerung. Gewinn: Eine
Turtle tief in der Mine wird nicht mehr eingefroren und fälschlich als „lost“ angezeigt.

**Code (Vorschlag):**

1. `turtle/gear.lua`, `fixed()`: Der Chunky kommt zu Chat Box und festem Modem auf die Liste der Seiten, die nie
   getauscht werden. Sonst könnte `toolSide()` bei fehlender Spitzhacke die Chunky-Seite wählen.
2. `turtle/gear.lua`: Chunky erkennen. Die CC-Version im Spiel (1.115) kennt `getEquipped*` nicht; Ausgerüstetes
   wird nur über den Peripheral-Typ erkannt. Den Typ des Chunky liefert `diag gear` im Spiel (Test 1 unten). In
   `PTYPE` eintragen.
3. `turtle/jobrunner.lua` (`M.GEAR`, `PATTERN`) und `central/jobsvc.lua` (`REQUIRES` für Mining-Aufträge): Chunky
   als Pflicht-Ausrüstung. Das Modem gilt dann nicht mehr als „fest ausgerüstet“, sondern liegt im Inventar.
4. Tests: Tausch nimmt nie die Chunky-Seite; Sync und Scan mit Chunky auf einer Seite und Spitzhacke auf der anderen.

**Risiko:** Fehlt das Modem im Inventar, kann die Turtle nicht funken (Gateway zeigt „verspätet“ → „overdue“ →
„lost“). Der Worker merkt das schon heute (`gear.has("modem")`) und holt im Leerlauf eins aus der Toolbox; die
Zwischenkiste nimmt das Modem nicht auf, solange TurtleMQ an ist.

---

## B. Barrel als Zwischenlager („Rucksack“)

Sophisticated Storage ist im Modpack. Dessen Barrel lässt sich mit Upgrades und Stufen (Copper bis Netherite) stark
vergrößern (größere Stapel) und **behält laut Beschreibung seinen Inhalt beim Abbauen**.

**Ablauf während des Auftrags:**

1. Am Einstieg stellt die Turtle das Barrel an die Oberfläche neben den Schacht. Das ist der Platz, an dem heute die
   Zwischenkiste steht (`mine.placeChestBeside`).
2. Bei vollem Inventar fährt sie nur den Schacht hoch zum Barrel und lädt dort ab, statt über Y 110 zum Lager. Das
   sind ein paar Dutzend statt 300–400 Bewegungen.
3. Fuel holt sie weiterhin am Lager, wenn es knapp wird; mit vollem Tank (`claude.fuel_target` 19000, Review R16)
   selten.

**Ablauf am Ende:**

1. Barrel abbauen (es behält den Inhalt) und mitnehmen.
2. Am Lagerplatz wie immer hinstellen: Connector **hinten**, Kohle **unten**.
3. Barrel **vorne** hinstellen, mit `suck` vorne herausholen, mit `drop` hinten in Tom's Storage schieben, bis es
   leer ist (pro `suck` höchstens 64, also mehrere Durchgänge).
4. Barrel wieder abbauen, es bleibt im Inventar für den nächsten Auftrag.

**Code (Vorschlag):**

1. Zwischenkiste wird zum Barrel: `placeChest` / `placeChestBeside` / `retrieveChest` / `fetchChest` (`turtle/mine.lua`)
   suchen statt `minecraft:chest` das Barrel (Itemname aus Test 2). `gear.isGear` und die Toolbox-Erkennung kennen es.
2. `unloadAndReturn`: bei vollem Inventar zum Barrel statt zum Lager (Schacht hoch, abladen, zurück). Zum Lager nur
   noch, wenn Fuel knapp ist oder das Barrel voll.
3. Neu in `turtle/nav.lua`: Ausladen am Lagerplatz aus einer mitgebrachten Box (vorne aufstellen, holen, hinten
   abgeben, wieder abbauen).
4. Barrel und Shulker stehen auf der Schutzliste (`zones.lua`). Die eigene Box baut die Turtle wie heute die eigene
   Kiste direkt ab (`turtle.dig`, nicht `nav.dig`) und merkt sich die Stelle (`job.chest`), auch für Abbruch.
5. `stonehunt` und R19 (echte Zähler): Abgeliefertes ins Barrel zählt als gesammelt; abgeliefert ins Lager erst am
   Ende.
6. Tests: Ausladen ins Barrel bei vollem Inventar, Leeren am Lagerplatz, Abbruch holt das Barrel mit Inhalt.

**Ersatz, falls das Barrel nicht passt:** Sophisticated-Shulkerbox (nimmt dieselben Upgrades) oder Vanilla-Shulkerbox
(27 Slots). Der Ablauf bleibt gleich.

---

## Tests im Spiel (vor dem Bauen)

| # | Was | Wie | Wofür |
|---|---|---|---|
| 1 | Wie erkennt die Turtle den Chunky? | Chunky an einer Seite ausrüsten, `diag gear`, Foto der Seiten-Zeilen | Teil A, Punkt 2 |
| 2 | Behält das Barrel den Inhalt, wenn die **Turtle** es abbaut? Wie heißt das Item? | Barrel mit ein paar Items vor die Turtle stellen, im Terminal `lua` → `turtle.dig()`, dann `turtle.getItemDetail(1, true)` | Teil B, und ob Barrel oder Shulker |
| 3 | Klappt `drop` und `suck` mit Stack-Upgrade? | 2 Stapel Bruchstein ins aufgerüstete Barrel `drop`pen, dann `suck` | Teil B, Ausladen |
| 4 | Ist am Lagerplatz vorne frei? | hinschauen | Teil B, Leeren am Lager |
| 5 | (optional) Gibt es einen Chunkloader-Block oder eine Ender-Truhe? | JEI: `chunk`, `loader`, `ender` | Alternativen |

CC-Version im Spiel: 1.115 (laut Spieler).

---

## Weitere Ideen aus dem Gespräch

- **Kurier statt Rucksack:** Ein Courier (Whitepaper 5.2) leert die Box am Einstieg regelmäßig, der Miner gräbt
  durch. Sinnvoll, sobald mehrere Miner laufen.
- **Halbe Stapel zusammenlegen** (`turtle.transferTo`), bevor das Inventar als voll gilt.
- **Verzauberte Spitzhacke:** CC:Tweaked kann Werkzeuge mit Verzauberungen seit 1.106, aber nur wenn ein Datapack
  das für das Werkzeug einschaltet (`allowEnchantments`). Ohne Datapack lässt sie sich nicht ausrüsten.
- **Umbenennen:** `stonehunt` später in `blockhunt` umbenennen (sammelt beliebige Blöcke, nicht nur Stein).

## Empfohlene Reihenfolge

1. Tests 1–4 im Spiel.
2. Teil A (Chunky), klein und unabhängig.
3. Teil B (Barrel), danach R19 (echte Zähler) darauf aufbauen.
