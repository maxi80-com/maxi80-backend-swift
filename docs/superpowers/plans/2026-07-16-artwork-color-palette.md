# Artwork Color Palette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store Apple Music's full color palette (bgColor + textColor1..4) in `metadata.json` and `history.json` instead of a single backend-derived `color`, so the client owns all color-selection decisions and no future look change requires a backfill.

**Architecture:** The backend becomes a faithful cache of Apple's palette; the "which color to paint" heuristic moves out of the backend to the client. The collector writes an `ArtworkColors` struct (5 hexes) in place of the single `color` field. The lambda's lazy color-backfill branch is removed (it re-called Apple Music and wrote the old schema). A one-off shell script converts the 2,571 existing `metadata.json` objects from the co-located `search.json` (no Apple Music calls, ~$0.02, verified: every track has a `search.json`).

**Tech Stack:** Swift 6.3 (server-side, AWS Lambda), Swift Testing, SwiftPM, `jq` + AWS CLI (bash) for the one-off backfill.

## Global Constraints

- Swift tools version **6.3**; first-party targets compile with **warnings-as-errors** plus upcoming features `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`, `NonisolatedNonsendingByDefault`. Use `any` on existentials; `public import` where a dependency type is in public API.
- Do **not** apply strict settings to `Sources/Soto/`.
- New JSON fields use `encodeIfPresent` / `decodeIfPresent` so absent/nil is omitted (matches existing `color` handling).
- Test framework is **Swift Testing** (`@Test`, `#expect`, `#require`, `@Suite`) — never XCTest.
- Run `make format` (swift-format) before each commit.
- Hex color contract: `"#RRGGBB"` uppercase.
- S3: bucket `artwork.maxi80.com`, prefix `v2/`, region `eu-central-1`, profile `maxi80`. Objects at `v2/<artist>/<title>/{metadata.json,search.json,artwork.jpg}`.
- **Schema is NOT backward compatible and does not need to be** — nothing is released. The migration (Task 5) converts all existing objects; no dual-read of old `color` is required anywhere.

---

## File Structure

- `Sources/IcecastMetadataCollector/ArtworkColors.swift` — **new.** `ArtworkColors` value type: the 5 normalized hexes, `Codable`, built from an Apple `Song.Attributes.Artwork`.
- `Sources/IcecastMetadataCollector/DominantColor.swift` — **shrink.** Keep only `normalizedHex(fromAppleBgColor:)` (still needed to normalize hexes). Delete `dominantHex(...)` and the HSV/RGB helpers — color *selection* is now the client's job.
- `Sources/IcecastMetadataCollector/CollectedMetadata.swift` — replace `color: String?` with `colors: ArtworkColors?`.
- `Sources/IcecastMetadataCollector/HistoryManager.swift` — `HistoryEntry.color: String?` → `colors: ArtworkColors?`; update `recordEntry` param.
- `Sources/IcecastMetadataCollector/MetadataCollector.swift` — `HistoryOutcome.color` → `colors`; `dominantColor(for:)` → `artworkColors(for:)`; **delete** the lazy backfill branch; update fresh-collection + migration branches.
- `scripts/backfill-colors.sh` — **new.** One-off S3 migration.
- Tests: `Tests/Maxi80BackendTests/DominantColorTests.swift` (trim), `ArtworkColorsTests.swift` (**new**), `MetadataCollectorTests.swift` (update assertions).

### Target `ArtworkColors` JSON shape (in metadata.json and each history entry)

```json
"colors": {
  "bg":    "#1C2520",
  "text1": "#E6B996",
  "text2": "#DDB5B1",
  "text3": "#BE9C7E",
  "text4": "#B69894"
}
```

---

## Task 1: `ArtworkColors` value type

**Files:**
- Create: `Sources/IcecastMetadataCollector/ArtworkColors.swift`
- Test: `Tests/Maxi80BackendTests/ArtworkColorsTests.swift`

**Interfaces:**
- Consumes: `DominantColor.normalizedHex(fromAppleBgColor:)` (existing, kept), `Song.Attributes.Artwork` from `Maxi80Backend` (fields `bgColor, textColor1..4: String`).
- Produces:
  - `struct ArtworkColors: Codable, Sendable, Equatable` with `let bg, text1, text2, text3, text4: String` (each `"#RRGGBB"` uppercase) and coding keys `bg, text1, text2, text3, text4`.
  - `init?(artwork: Song.Attributes.Artwork)` — returns `nil` if any of the 5 hexes fails normalization; otherwise all normalized.

- [ ] **Step 1: Write the failing test**

Create `Tests/Maxi80BackendTests/ArtworkColorsTests.swift`:

Note: the codebase constructs Apple model types via **JSON decode**, not memberwise init
(`Song.Attributes.Artwork` has no `public init`, and existing tests decode from JSON — see
`SongSelectorTests`). Follow that pattern: decode an `Artwork` from a JSON literal.

```swift
import Testing

@testable import IcecastMetadataCollector
@testable import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite("ArtworkColors Tests")
struct ArtworkColorsTests {

    /// Decodes a `Song.Attributes.Artwork` from JSON (the model has no public memberwise init;
    /// the codebase builds these types by decoding, matching SongSelectorTests).
    private func artwork(bg: String, t1: String, t2: String, t3: String, t4: String) throws
        -> Song.Attributes.Artwork
    {
        let json = """
            {"width":1000,"height":1000,"url":"https://example/{w}x{h}.jpg",
             "bgColor":"\(bg)","textColor1":"\(t1)","textColor2":"\(t2)",
             "textColor3":"\(t3)","textColor4":"\(t4)"}
            """
        return try JSONDecoder().decode(Song.Attributes.Artwork.self, from: Data(json.utf8))
    }

    @Test("Builds normalized (# + uppercase) colors from Apple artwork")
    func buildsNormalizedColors() throws {
        let colors = try #require(
            ArtworkColors(artwork: try artwork(bg: "1c2520", t1: "e6b996", t2: "ddb5b1", t3: "be9c7e", t4: "b69894"))
        )
        #expect(colors.bg == "#1C2520")
        #expect(colors.text1 == "#E6B996")
        #expect(colors.text2 == "#DDB5B1")
        #expect(colors.text3 == "#BE9C7E")
        #expect(colors.text4 == "#B69894")
    }

    @Test("Returns nil when any Apple color is malformed")
    func nilOnMalformed() throws {
        let art = try artwork(bg: "zzz", t1: "e6b996", t2: "ddb5b1", t3: "be9c7e", t4: "b69894")
        #expect(ArtworkColors(artwork: art) == nil)
    }

    @Test("Round-trips through JSON with the client-contract keys")
    func jsonRoundTrip() throws {
        let colors = try #require(
            ArtworkColors(artwork: try artwork(bg: "000000", t1: "ffffff", t2: "cccccc", t3: "999999", t4: "666666"))
        )
        let data = try JSONEncoder().encode(colors)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"bg\":\"#000000\""))
        #expect(json.contains("\"text1\":\"#FFFFFF\""))
        let decoded = try JSONDecoder().decode(ArtworkColors.self, from: data)
        #expect(decoded == colors)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ArtworkColorsTests`
Expected: FAIL — `cannot find 'ArtworkColors' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/IcecastMetadataCollector/ArtworkColors.swift`:

```swift
import Maxi80Backend

/// Apple Music's full artwork color palette, stored verbatim (normalized to the client hex
/// contract) so the client — not the backend — decides how to render it. Replaces the previous
/// single backend-derived `color`, which baked a presentation decision into the cache and forced a
/// backfill whenever that decision changed.
struct ArtworkColors: Codable, Sendable, Equatable {
    /// Apple's precomputed background color ("#RRGGBB", uppercase).
    let bg: String
    /// Apple's four foreground/text colors ("#RRGGBB", uppercase), carrying the vivid tones.
    let text1: String
    let text2: String
    let text3: String
    let text4: String

    enum CodingKeys: String, CodingKey { case bg, text1, text2, text3, text4 }

    init(bg: String, text1: String, text2: String, text3: String, text4: String) {
        self.bg = bg
        self.text1 = text1
        self.text2 = text2
        self.text3 = text3
        self.text4 = text4
    }

    /// Builds the palette from an Apple artwork, normalizing every hex to "#RRGGBB" uppercase.
    /// Returns nil if any of the five values is not a valid 6-digit hex.
    init?(artwork: Song.Attributes.Artwork) {
        let normalizer = DominantColor()
        guard let bg = normalizer.normalizedHex(fromAppleBgColor: artwork.bgColor),
            let text1 = normalizer.normalizedHex(fromAppleBgColor: artwork.textColor1),
            let text2 = normalizer.normalizedHex(fromAppleBgColor: artwork.textColor2),
            let text3 = normalizer.normalizedHex(fromAppleBgColor: artwork.textColor3),
            let text4 = normalizer.normalizedHex(fromAppleBgColor: artwork.textColor4)
        else { return nil }
        self.init(bg: bg, text1: text1, text2: text2, text3: text3, text4: text4)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ArtworkColorsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Format and commit**

```bash
make format
git add Sources/IcecastMetadataCollector/ArtworkColors.swift Tests/Maxi80BackendTests/ArtworkColorsTests.swift
git commit -m "feat: add ArtworkColors palette type from Apple Music artwork"
```

---

## Task 2: Trim `DominantColor` to the normalizer only

**Files:**
- Modify: `Sources/IcecastMetadataCollector/DominantColor.swift`
- Modify: `Tests/Maxi80BackendTests/DominantColorTests.swift`

**Interfaces:**
- Produces: `DominantColor.normalizedHex(fromAppleBgColor:) -> String?` (unchanged signature; sole remaining method).
- Removes: `dominantHex(bgColor:textColors:)` and the private `rgb(fromHex:)` / `saturationValue(_:)` helpers and the `minSaturation`/`minValue` constants. Color *selection* now lives in the client.

- [ ] **Step 1: Replace `DominantColor.swift` with the normalizer-only version**

```swift
import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct DominantColor {

    /// Normalizes an Apple Music color (`bgColor` or `textColorN`) into the client contract format.
    /// Apple returns 6 hex digits without a leading `#` and of unspecified case (e.g. "3d2a1c").
    /// Returns "#RRGGBB" uppercase, or nil if the input is not exactly 6 hex digits.
    func normalizedHex(fromAppleBgColor raw: String) -> String? {
        var value = raw.trimmingWhitespace()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + value.uppercased()
    }
}
```

- [ ] **Step 2: Delete the now-removed `dominantHex` tests**

In `Tests/Maxi80BackendTests/DominantColorTests.swift`, delete everything from the line `// MARK: - dominantHex: fall back off a grey/dark bgColor to the vivid text color` through the end of the last `dominantHex_*` test, leaving the closing `}` of the suite. Keep all `normalizedHex_*` tests intact (they still validate the surviving method).

- [ ] **Step 3: Build to confirm nothing else references the removed API**

Run: `swift build`
Expected: FAIL — `MetadataCollector.swift` still calls `dominantHex`/`dominantColor(for:)`. This is expected; Task 3 fixes it. (If you are running tasks strictly in order and want a green build here, do Task 3 before building. Otherwise proceed — Task 3 resolves it.)

- [ ] **Step 4: (Deferred verification)**

The green build+test checkpoint for this change is at the end of Task 3, once the collector is migrated. Do not commit Task 2 alone if `swift build` is red — commit Tasks 2 and 3 together at Task 3, Step 8.

---

## Task 3: Collector writes `ArtworkColors`; delete lazy backfill

**Files:**
- Modify: `Sources/IcecastMetadataCollector/CollectedMetadata.swift`
- Modify: `Sources/IcecastMetadataCollector/HistoryManager.swift`
- Modify: `Sources/IcecastMetadataCollector/MetadataCollector.swift`
- Modify: `Tests/Maxi80BackendTests/MetadataCollectorTests.swift`

**Interfaces:**
- Consumes: `ArtworkColors` (Task 1), `ArtworkColors(artwork:)`.
- Produces:
  - `CollectedMetadata.colors: ArtworkColors?` (replaces `color: String?`); init param `colors: ArtworkColors? = nil`; coding key `colors`.
  - `HistoryEntry.colors: ArtworkColors?` (replaces `color`); init param `colors: ArtworkColors? = nil`; coding key `colors`.
  - `HistoryManager.recordEntry(artist:title:artworkKey:timestamp:colors:logger:)` (param `color:` → `colors: ArtworkColors?`).
  - `MetadataCollector.HistoryOutcome.colors: ArtworkColors?` (replaces `color`).
  - `MetadataCollector.artworkColors(for song: Song) -> ArtworkColors?` (replaces `dominantColor(for:)`).

- [ ] **Step 1: Update `CollectedMetadata` — swap `color` for `colors`**

Replace the body of `Sources/IcecastMetadataCollector/CollectedMetadata.swift` with:

```swift
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct CollectedMetadata: Codable, Sendable {
    let rawMetadata: String  // Original Icecast StreamTitle value
    let artist: String  // Parsed artist name
    let title: String  // Parsed title
    let collectedAt: String  // ISO 8601 timestamp
    let colors: ArtworkColors?  // Apple Music artwork palette, or nil (omitted from JSON)

    init(rawMetadata: String, artist: String, title: String, collectedAt: String, colors: ArtworkColors? = nil) {
        self.rawMetadata = rawMetadata
        self.artist = artist
        self.title = title
        self.collectedAt = collectedAt
        self.colors = colors
    }

    enum CodingKeys: String, CodingKey { case rawMetadata, artist, title, collectedAt, colors }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawMetadata = try container.decode(String.self, forKey: .rawMetadata)
        artist = try container.decode(String.self, forKey: .artist)
        title = try container.decode(String.self, forKey: .title)
        collectedAt = try container.decode(String.self, forKey: .collectedAt)
        colors = try container.decodeIfPresent(ArtworkColors.self, forKey: .colors)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawMetadata, forKey: .rawMetadata)
        try container.encode(artist, forKey: .artist)
        try container.encode(title, forKey: .title)
        try container.encode(collectedAt, forKey: .collectedAt)
        try container.encodeIfPresent(colors, forKey: .colors)
    }
}
```

- [ ] **Step 2: Update `HistoryEntry` + `recordEntry` in `HistoryManager.swift`**

In `Sources/IcecastMetadataCollector/HistoryManager.swift`, change the `HistoryEntry` struct's color field, init, coding keys, and codable bodies from `color: String?` to `colors: ArtworkColors?`:

- Field: replace `let color: String?  // ...` with `let colors: ArtworkColors?  // Apple Music artwork palette, or nil (omitted from JSON)`
- Init: `init(artist: String, title: String, artwork: String, timestamp: String, colors: ArtworkColors? = nil)` and `self.colors = colors`
- Coding keys: `enum CodingKeys: String, CodingKey { case artist, title, artwork, timestamp, colors }`
- Decode: `colors = try container.decodeIfPresent(ArtworkColors.self, forKey: .colors)`
- Encode: `try container.encodeIfPresent(colors, forKey: .colors)`

Then update `recordEntry` (currently param `color: String? = nil` at line ~95) and its `HistoryEntry(...)` construction (line ~114):

```swift
    func recordEntry(
        artist: String,
        title: String,
        artworkKey: String,
        timestamp: String,
        colors: ArtworkColors? = nil,
        logger: Logger
    ) async {
```

and

```swift
        let entry = HistoryEntry(artist: artist, title: title, artwork: artworkKey, timestamp: timestamp, colors: colors)
```

- [ ] **Step 3: Update `MetadataCollector` — `HistoryOutcome`, `artworkColors(for:)`, fresh + migration branches**

In `Sources/IcecastMetadataCollector/MetadataCollector.swift`:

(a) `HistoryOutcome` (lines ~41-47) — rename `color` to `colors`:

```swift
    /// What to write to history for this invocation: the artwork file name (`artwork.jpg` or
    /// `nocover.jpg`) and the optional palette. `nil` from `enrich` means "dedup skip —
    /// record nothing".
    private struct HistoryOutcome {
        let file: String
        let colors: ArtworkColors?
    }
```

(b) The catch fallback in `collect()` (line ~89): `outcome = HistoryOutcome(file: "nocover.jpg", color: nil)` → `outcome = HistoryOutcome(file: "nocover.jpg", colors: nil)`.

(c) The `recordHistory` call in `collect()` (line ~97):

```swift
        await recordHistory(artist: artist, title: title, file: outcome.file, colors: outcome.colors, logger: logger)
```

(d) Maxi80-filler branch (line ~130): `return HistoryOutcome(file: "nocover.jpg", color: nil)` → `colors: nil`.

(e) Replace `dominantColor(for:)` (lines ~322-331) with:

```swift
    /// The Apple Music artwork palette to store, or nil when no artwork/valid colors are available.
    private func artworkColors(for song: Song) -> ArtworkColors? {
        song.attributes.artwork.flatMap { ArtworkColors(artwork: $0) }
    }
```

(f) Fresh-collection branch (lines ~259-280) — replace the `artworkColor` derivation, the `CollectedMetadata(... color:)` write, and the return:

```swift
        // Capture Apple's full artwork palette and cache it in metadata.json so future cache hits
        // reuse it without calling Apple Music again. The client picks the display color.
        let colors = artworkColors(for: song)

        // Step 7: Upload all three files to S3
        let collectedMetadata = CollectedMetadata(
            rawMetadata: rawMetadata,
            artist: artist,
            title: title,
            collectedAt: Date.now.formatted(.iso8601),
            colors: colors
        )

        try await s3Writer.writeMetadata(collectedMetadata, artist: artist, title: title, logger: logger)
        try await s3Writer.writeSearchResults(searchData, artist: artist, title: title, logger: logger)
        if let artworkData {
            try await s3Writer.writeArtwork(artworkData, artist: artist, title: title, logger: logger)
        }

        let file = artworkData != nil ? "artwork.jpg" : "nocover.jpg"
        logger.debug("Path: fresh collection complete → recording \(file)")
        return HistoryOutcome(file: file, colors: colors)
```

(g) `recordHistory` signature + body (lines ~283-296):

```swift
    private func recordHistory(artist: String, title: String, file: String, colors: ArtworkColors? = nil, logger: Logger)
        async
    {
        let artworkKey = buildS3Key(prefix: s3Writer.config.keyPrefix, artist: artist, title: title, file: file)
        let timestamp = Date.now.formatted(.iso8601)
        logger.debug("recordHistory: artist=\(artist), title=\(title), file=\(file), colors=\(colors != nil)")
        await historyManager.recordEntry(
            artist: artist,
            title: title,
            artworkKey: artworkKey,
            timestamp: timestamp,
            colors: colors,
            logger: logger
        )
    }
```

- [ ] **Step 4: Delete the lazy backfill branch and simplify the cache-hit path**

In `MetadataCollector.enrich`, replace the entire cache-hit block (currently lines ~133-173, from `// Step 3: Check S3 cache` through the `return HistoryOutcome(file: "artwork.jpg", color: color)`) with:

```swift
        // Step 3: Check S3 cache — if already collected, reuse the cached palette instead of
        // calling Apple Music again. (The one-off scripts/backfill-colors.sh converts any objects
        // collected before the palette schema, so there is no lazy per-request backfill here.)
        logger.debug("Path: checking S3 cache for \(artist)/\(title)")
        if let cached = try await s3Writer.readMetadata(artist: artist, title: title) {
            logger.info("Cache hit for \(artist)/\(title), skipping collection")
            logger.debug("Path: cache hit → recording artwork")
            return HistoryOutcome(file: "artwork.jpg", colors: cached.colors)
        }
```

Then in the migration branch, update the two `legacy.color` references (lines ~209 and ~223): `color: legacy.color` → `colors: legacy.colors`, and `return HistoryOutcome(file: "artwork.jpg", color: legacy.color)` → `return HistoryOutcome(file: "artwork.jpg", colors: legacy.colors)`.

- [ ] **Step 5: Update `MetadataCollectorTests` assertions and fixtures**

In `Tests/Maxi80BackendTests/MetadataCollectorTests.swift`:

- `metadataJSON(...)` helper (lines ~41-50): change signature `color: String?` → `colors: ArtworkColors?` and pass `colors: colors` into `CollectedMetadata`. Update the two call sites in `migratesStrippedTitleToFullTitle` / `fullTitleCacheHitNoMigration` that pass `color: "#0D0F11"` to pass a palette instead:

```swift
    static let sampleColors = ArtworkColors(
        bg: "#0D0F11", text1: "#FFFFFF", text2: "#CCCCCC", text3: "#999999", text4: "#666666"
    )
```
  and use `colors: Self.sampleColors` at those call sites.

- In `migratesStrippedTitleToFullTitle`, the migrated-metadata assertion (line ~100) `#expect(migrated.color == "#0D0F11")` → `#expect(migrated.colors == Self.sampleColors)`; and the history-entry assertion (line ~114) `#expect(entry.color == "#0D0F11")` → `#expect(entry.colors == Self.sampleColors)`.

- The Apple Music fixture `SongSelectorTests.searchResponseJSON` includes `bgColor 000000` + textColors (`ffffff/cccccc/999999/666666`). `freshCollectionRecordsExactlyOnce` currently asserts only `entries.count == 1` and `entries.last?.artwork.hasSuffix("/artwork.jpg")`. ADD one assertion right after those, verifying the palette is stored end-to-end from the fixture:

```swift
        #expect(entries.last?.colors == ArtworkColors(
            bg: "#000000", text1: "#FFFFFF", text2: "#CCCCCC", text3: "#999999", text4: "#666666"))
```
  This is the single fresh-collection test that exercises the palette write path, so the assertion is worth adding here specifically.

- [ ] **Step 6: Build**

Run: `swift build`
Expected: PASS (Task 2's removal is now consistent with the collector).

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS. Watch specifically for `MetadataCollectorTests`, `ArtworkColorsTests`, `DominantColorTests`, `HistoryManagerTests`.

- [ ] **Step 8: Format and commit (Tasks 2 + 3 together)**

```bash
make format
git add Sources/IcecastMetadataCollector Tests/Maxi80BackendTests
git commit -m "feat: store full Apple Music color palette; remove lazy color backfill

Replace the single derived color field in metadata.json/history.json with
Apple's full palette (bg + text1..4). Color selection moves to the client.
Delete the lambda's lazy color-backfill branch (superseded by a one-off
migration, scripts/backfill-colors.sh)."
```

---

## Task 4: One-off S3 backfill script

**Files:**
- Create: `scripts/backfill-colors.sh`

**Interfaces:**
- Consumes: nothing from the Swift code (standalone). Reads `v2/*/*/search.json`, writes `v2/*/*/metadata.json`.
- Produces: each `metadata.json` gains a `colors` object and drops the old `color` field. Selection of the source song matches `selectBestMatch`: **first song with an `artwork` object, else first song.**

**Behavior contract (must match the Swift collector):**
- Palette source: `.results.songs.data[]` → first element whose `.attributes.artwork` is non-null, else `.data[0]`.
- Each of `bgColor, textColor1..4` normalized to `"#" + uppercase`, only if a valid 6-hex-digit string; if the chosen song has no artwork or a color is invalid, that track is **skipped** (left unchanged) and counted.
- `--dry-run` (default ON): report per-track decision and totals, write nothing. `--apply` performs the PUTs.
- Idempotent: safe to re-run; a metadata.json that already has `colors` and no `color` is left unchanged.

- [ ] **Step 1: Write the script**

Create `scripts/backfill-colors.sh`:

```bash
#!/usr/bin/env bash
#
# One-off migration: convert every v2/<artist>/<title>/metadata.json from the old single-`color`
# field to the new `colors` palette (bg + text1..4), sourced from the co-located search.json.
# No Apple Music calls — search.json already contains Apple's palette. ~2,571 tracks, ~$0.02.
#
# The chosen song matches the collector's selectBestMatch: first song WITH artwork, else first song.
#
# DEFAULT IS DRY-RUN. Pass --apply to actually write. Idempotent; safe to re-run.
#
# Usage:
#   scripts/backfill-colors.sh            # dry-run: report only
#   scripts/backfill-colors.sh --apply    # perform the migration
#   AWS_PROFILE=maxi80 scripts/backfill-colors.sh --apply
#
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-maxi80}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
BUCKET="${BUCKET:-artwork.maxi80.com}"
PREFIX="${PREFIX:-v2}"

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

aws() { command aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

echo "Mode:   $([ $APPLY -eq 1 ] && echo APPLY || echo 'DRY-RUN (pass --apply to write)')"
echo "Bucket: s3://$BUCKET/$PREFIX/"
echo

# jq program: given a search.json, emit the palette JSON object or empty on failure.
# Picks first song with artwork, else first song; normalizes each hex to #UPPER; requires all 5.
read -r -d '' JQ_PALETTE <<'JQ' || true
def norm:
  if type=="string" and test("^#?[0-9a-fA-F]{6}$")
  then (ltrimstr("#") | ascii_upcase | "#" + .)
  else null end;
(.results.songs.data // []) as $songs
| ( [ $songs[] | select(.attributes.artwork != null) ][0] // $songs[0] ) as $song
| ($song.attributes.artwork) as $a
| if $a == null then empty
  else
    { bg: ($a.bgColor|norm),
      text1: ($a.textColor1|norm), text2: ($a.textColor2|norm),
      text3: ($a.textColor3|norm), text4: ($a.textColor4|norm) }
    | if (to_entries | all(.value != null)) then . else empty end
  end
JQ

converted=0; skipped=0; unchanged=0; total=0

# List every metadata.json key under the prefix.
while IFS= read -r key; do
  [ -z "$key" ] && continue
  total=$((total+1))
  dir="${key%/metadata.json}"
  search_key="$dir/search.json"

  meta_json="$(aws s3 cp "s3://$BUCKET/$key" - 2>/dev/null || true)"
  [ -z "$meta_json" ] && { echo "SKIP (no metadata): $key"; skipped=$((skipped+1)); continue; }

  # Already migrated? has colors and no legacy color -> leave as is.
  if echo "$meta_json" | jq -e 'has("colors") and (has("color")|not)' >/dev/null 2>&1; then
    unchanged=$((unchanged+1)); continue
  fi

  search_json="$(aws s3 cp "s3://$BUCKET/$search_key" - 2>/dev/null || true)"
  [ -z "$search_json" ] && { echo "SKIP (no search.json): $dir"; skipped=$((skipped+1)); continue; }

  palette="$(echo "$search_json" | jq -c "$JQ_PALETTE" 2>/dev/null || true)"
  [ -z "$palette" ] && { echo "SKIP (no usable palette): $dir"; skipped=$((skipped+1)); continue; }

  # Merge: add colors, drop legacy color.
  new_meta="$(echo "$meta_json" | jq -c --argjson c "$palette" '.colors=$c | del(.color)')"

  if [ $APPLY -eq 1 ]; then
    echo "$new_meta" | aws s3 cp - "s3://$BUCKET/$key" --content-type application/json >/dev/null
    echo "CONVERTED: $dir -> $palette"
  else
    echo "WOULD CONVERT: $dir -> $palette"
  fi
  converted=$((converted+1))
done < <(aws s3 ls "s3://$BUCKET/$PREFIX/" --recursive | awk '{print $4}' | grep '/metadata.json$')

echo
echo "── Summary ─────────────────────────────"
echo "total metadata.json: $total"
echo "converted:           $converted$([ $APPLY -eq 0 ] && echo ' (dry-run, not written)')"
echo "already migrated:    $unchanged"
echo "skipped:             $skipped"
```

- [ ] **Step 2: Make executable and syntax-check**

```bash
chmod +x scripts/backfill-colors.sh
bash -n scripts/backfill-colors.sh
```
Expected: no output (syntax OK).

- [ ] **Step 3: Dry-run against S3 (read-only)**

Run: `AWS_PROFILE=maxi80 scripts/backfill-colors.sh`
Expected: prints `WOULD CONVERT: …` lines and a summary. `total metadata.json` should be ~2571; nothing written. Spot-check one `WOULD CONVERT` palette against the corresponding `search.json` by eye (e.g. the Jeanne Mas track → bg `#1C2520`).

- [ ] **Step 4: Commit the script (dry-run verified, not yet applied)**

```bash
git add scripts/backfill-colors.sh
git commit -m "feat: add one-off backfill-colors.sh to migrate metadata.json to palette schema"
```

- [ ] **Step 5: Apply the migration (deliberate, after schema deploy — see Task 5)**

Do NOT run this until the Task 3 schema change is deployed (so the collector and stored data agree). Then:

Run: `AWS_PROFILE=maxi80 scripts/backfill-colors.sh --apply`
Expected: `CONVERTED: …` lines; summary `converted` ≈ number of pre-migration tracks, `skipped` = tracks whose search.json had no usable artwork palette. Re-run once to confirm idempotency: second run should show `already migrated` ≈ total and `converted: 0`.

---

## Task 5: Deploy + rollout ordering

**Files:** none (operational).

**Interfaces:** none.

This task documents the ONE ordering constraint that matters: the collector must be writing the new schema before (or at the same time as) the backfill runs, and the CI pipeline deploys on push to main.

- [ ] **Step 1: Confirm green locally**

Run: `swift build && swift test`
Expected: PASS.

- [ ] **Step 2: Merge to main → CI deploys**

Pushing/merging Tasks 1-4 to `main` triggers `.github/workflows/deploy.yml` (test → cross-compile → `sam deploy`). Confirm the deploy succeeds (Actions tab / `make logs-collector`). After this, the collector writes `colors`.

- [ ] **Step 3: Run the backfill with `--apply`**

Now perform Task 4, Step 5 (`scripts/backfill-colors.sh --apply`). This converts the existing 2,571 objects so the whole store is uniform palette schema.

- [ ] **Step 4: Spot-check**

```bash
aws s3 cp "s3://artwork.maxi80.com/v2/Jeanne Mas/L'enfant/metadata.json" - --region eu-central-1 --profile maxi80 | jq .
```
Expected: a `colors` object (`bg #1C2520`, `text1 #E6B996`, …) and no `color` field.

---

## Notes / out of scope

- **Client changes are NOT in this plan** (separate repo). The client must (a) read `colors` from history entries, (b) implement the display-color selection (the grey-bg → most-saturated-text heuristic that used to live in `DominantColor.dominantHex`, now the client's responsibility, runs on Android via Skip as pure arithmetic). Flag this to the client work.
- The API Lambda (`/history`, `/artwork`) streams `history.json`/presigns URLs and does not parse `color` — no change needed there (verified: no color references in `Sources/Maxi80Lambda`).
- Backfill cost (measured): 2,571 tracks × (1 GET search.json + 1 PUT metadata.json), same region, no Apple Music calls, no artwork reads → ≈ **$0.014** in S3 request charges; minutes of wall-clock.
- **True image sampling** (reading `artwork.jpg` pixels to get the real dominant hue) was considered and rejected: it needs an image-decode dependency in the Linux Lambda and is unnecessary — Apple's palette + client selection is good enough.
```
