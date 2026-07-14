# SPEC: Artwork Dominant Color in `/history`

Status: Ready for implementation
Audience: An autonomous implementing agent working in `maxi-80-backend-swift`. This spec is self-contained; every instruction is grounded in the current codebase with file/line citations. Do not deviate from the **Contract** section — the client already depends on it.

---

## 1. Overview

The Maxi80 iOS/Android client renders a Cover Flow of recently played songs and paints the app background with a gradient derived from the **dominant color** of the currently shown artwork.

Today the client computes that color itself: it downloads each artwork JPEG, decodes it, downscales to 40×40, and averages the pixels (`Maxi80/Sources/Maxi80/ArtworkService.swift`, `averageColor(from:)`, lines 121–160). This is impossible on Android (no platform image APIs — the Android branch at lines 96–99 returns a default color and no image) and wasteful everywhere (every client re-downloads and re-decodes the same JPEG).

**Goal:** move dominant-color computation to the backend. Compute each song's artwork dominant color **once**, at collection time, in the collector Lambda (`IcecastMetadataCollector`), and store it inside each history entry in `history.json` on S3. The `/history` endpoint already serves `history.json` verbatim (`Sources/Maxi80Lambda/Actions.swift`, `HistoryAction.handle`, lines 138–147), so once the field is in the stored file it is exposed automatically. The client then reads a hex string instead of decoding pixels.

The client side is **already implemented and merged** — it decodes an optional `color` field. This spec only changes the backend. See §4 for the exact contract the client expects.

---

## 2. Current State (with citations)

### 2.1 The history entry model (what gets written to S3)

`Sources/IcecastMetadataCollector/HistoryManager.swift`, lines 10–19:

```swift
struct HistoryEntry: Codable, Sendable, Equatable {
    let artist: String
    let title: String
    let artwork: String    // Full S3 key, e.g. "collected/ArtistName/SongTitle/artwork.jpg"
    let timestamp: String  // ISO 8601 UTC, e.g. "2025-01-15T14:30:00Z"
}

struct HistoryFile: Codable, Sendable, Equatable {
    var entries: [HistoryEntry]
}
```

`HistoryEntry` has **no `CodingKeys`** — it relies on synthesized `Codable`, so the JSON keys are exactly the property names (`artist`, `title`, `artwork`, `timestamp`). This is the struct to extend.

### 2.2 How entries are created and written

- `HistoryManager.recordEntry(artist:title:artworkKey:timestamp:logger:)` — `HistoryManager.swift`, lines 56–80. Builds a `HistoryEntry` (line 72) and calls `appendAndTrim` then `writeHistory`. **This is the current entry-construction site and its signature must gain a `color` argument.**
- `HistoryManager.appendAndTrim(entry:to:maxSize:)` — lines 26–33. Pure function; unchanged by this spec.
- `HistoryManager.writeHistory(_:)` — lines 46–52. Encodes with `.sortedKeys`. Unchanged.
- `HistoryManager.readHistory()` — lines 37–43. Decodes `HistoryFile`. Must keep decoding old files that lack `color` (guaranteed if `color` is optional — see §8).

### 2.3 The collector flow (where color must be computed)

`Sources/IcecastMetadataCollector/Lambda.swift`:

- Artwork is downloaded at lines 180–188:
  ```swift
  let artworkData: Data?
  if let artwork = song.attributes.artwork {
      artworkData = try await artworkDownloader.download(artwork: artwork, logger: context.logger)
      ...
  } else {
      artworkData = nil
      ...
  }
  ```
  **`artworkData` (the JPEG bytes) is the natural input for color computation.**
- The entry is recorded via the private helper `recordHistory(artist:title:file:logger:)` at lines 210–214, which forwards to `historyManager.recordEntry(...)`. Note this helper takes a **file name** (`"artwork.jpg"` / `"nocover.jpg"`), not the image data.
- `recordHistory` is called from **five** sites (lines 140, 149, 174, 205, and via the cache-hit path 149). Only the cache-miss path at line 205 has freshly downloaded `artworkData`. The other paths (Maxi 80 house track line 140, cache hit line 149, no search results line 174) do **not** have image bytes in hand.

**Design implication:** compute color only where JPEG bytes are available (the cache-miss download path, line 200–205). All other paths pass `color: nil`. This is acceptable because those paths either use `nocover.jpg` (no meaningful color) or are cache hits whose color could be backfilled later (see §8 migration). Do **not** add an S3 fetch to recompute color on cache-hit paths in the initial implementation — that reintroduces per-collection cost. (A future enhancement may fetch-and-decode the cached artwork on cache hit; out of scope here.)

### 2.4 `ArtworkDownloader` — the download site

`Sources/IcecastMetadataCollector/ArtworkDownloader.swift`, lines 12–48. `download(artwork:logger:)` returns raw `Data` (the JPEG). It builds the URL from an Apple Music artwork template with `{w}`/`{h}` placeholders (`buildArtworkURL`, lines 43–47). The requested width/height come from `Song.Attributes.Artwork` (`Sources/Maxi80Backend/AppleMusic/AppleMusicModel.swift`, lines 120–122: `width`, `height` are `Int`). Apple Music artwork is typically large (hundreds to thousands of px per side), so the decoder must handle full-size baseline/progressive JPEG.

This file (or a new sibling type) is the recommended home for the color-computation helper (see §6).

### 2.5 The `/history` and `/artwork` endpoints

- `HistoryAction` (`Sources/Maxi80Lambda/Actions.swift`, lines 120–147): reads `"{keyPrefix}/history.json"` from S3 and returns the bytes **verbatim** (line 146). **No change required here** — once `color` is in the stored file, it flows through automatically. Returns `{"entries":[]}` when the file is absent (line 144).
- `ArtworkAction` (lines 45–98) and `ArtworkResponse` (lines 153–159): returns `{"url": "..."}` (a presigned S3 URL). Adding `color` here is **optional** and out of scope for the primary contract; if implemented, it is a nice-to-have described in §6.6, and must not break the existing `ArtworkResponse` decode on the client (`Maxi80/Sources/Maxi80/...` decodes `ArtworkURLResponse` with a `url` field only).

### 2.6 Endpoints enum & Station

- `Sources/Maxi80Backend/Endpoint.swift`, lines 11–15: `Maxi80Endpoint` has `.station`, `.artwork`, `.history`. No new endpoint is needed.
- `Sources/Maxi80Backend/Station.swift`: unrelated; no change.

### 2.7 Runtime & dependencies (critical constraint)

- `Package.swift` targets `.macOS(.v26)` and the Lambdas run on **Linux** (AWS Lambda). Throughout the collector, Foundation is imported as:
  ```swift
  #if canImport(FoundationEssentials)
  import FoundationEssentials
  #else
  import Foundation
  #endif
  ```
  (e.g. `HistoryManager.swift` lines 4–8, `ArtworkDownloader.swift` lines 6–10.)
- **There is no image-decoding capability on Linux here.** `CoreGraphics`, `ImageIO`, `UIKit`, `AppKit` are Apple-only and unavailable in the Lambda runtime. `FoundationEssentials` has **no** JPEG decoding. The current `Package.swift` dependencies are: `swift-aws-lambda-runtime`, `swift-aws-lambda-events`, `jwt-kit`, `swift-log`, `aws-sdk-swift`, `async-http-client`, `swift-argument-parser`. **None can decode a JPEG.**
- Therefore the implementer **must add a Linux-capable JPEG decoder dependency**. See §7 for the recommendation.

### 2.8 Existing tests to match

- `Tests/Maxi80BackendTests/HistoryManagerTests.swift`:
  - Property 1 "Serialization round-trip" (lines 48–58) — encodes/decodes `HistoryFile`, expects equality.
  - Property 2 "Serialized JSON structure contains required keys" (lines 92–107) — **asserts the entry JSON has EXACTLY the keys `{artist, title, artwork, timestamp}`** (line 100–101). **This test will break** once `color` is added and must be updated (see §9.3).
  - `HistoryEntry(...)` is constructed positionally in many test cases (e.g. lines 31–36, 327, 339–341). Adding a non-defaulted stored property would break all of them — the new property MUST be optional with a default, or a memberwise-compatible init must be preserved (see §6.2).
- `Tests/Maxi80BackendTests/ArtworkDownloaderTests.swift`: only tests URL templating and error type; a good home for new decode-related unit tests or a new sibling test file.
- `Tests/Maxi80BackendTests/ArtworkActionPropertyTests.swift`: tests `ArtworkAction`/`ArtworkResponse`. Only touch if you implement the optional §6.6 `/artwork` color.

---

## 3. Client contract reference (do not change; match exactly)

The client is already implemented. For grounding, its decode is:

- `Maxi80/Sources/Maxi80Model/Models/HistoryEntry.swift`: `CodingKeys` maps `case dominantColor = "color"` and decodes via `decodeIfPresent(RGBColor.self, forKey: .dominantColor)`. So the field is **optional** on the client too.
- `Maxi80/Sources/Maxi80Model/Models/RGBColor.swift`: decodes from a **single-value string**, `parse(hex:)` accepts `"#RRGGBB"` or `"RRGGBB"`, requires exactly 6 hex digits (line 38). Its own `hexString` getter emits uppercase `#RRGGBB` via `String(format: "#%02X%02X%02X", ...)` (lines 46–49).

The backend must emit exactly what this parser accepts, and ideally identical to what `hexString` produces.

---

## 4. Contract (EXACT — this is the deliverable)

Add an **optional** field named **`color`** to each history entry object in `history.json` (and therefore in the `/history` JSON response).

- **Field name:** `color` (lowercase, exactly).
- **Value type:** JSON string.
- **Format:** `"#RRGGBB"` — a leading `#`, then exactly 6 **uppercase** hexadecimal digits. Example: `"#1A2B3C"`.
- **Optionality:** the field is **omitted entirely** when no color could be computed (no artwork, or decode failure). It is never emitted as `null`, empty string, or a bogus placeholder.
- **Backward compatibility:** entries already in `history.json` without `color` must continue to decode and serve unchanged.

Example entry after the change:

```json
{"artist":"Sandra","title":"Secret Land","artwork":"v2/Sandra/Secret Land/artwork.jpg","timestamp":"2026-07-13T10:54:27Z","color":"#3D2A1C"}
```

Example entry with no artwork (color omitted, still valid):

```json
{"artist":"Maxi 80","title":"Jingle","artwork":"collected/Maxi 80/Jingle/nocover.jpg","timestamp":"2026-07-13T10:55:00Z"}
```

The color is computed **once** at collection time and stored in S3. It is **never** recomputed per `/history` request.

---

## 5. Algorithm (deterministic; matches the client's current average)

Given the downloaded artwork JPEG bytes:

1. **Decode** the JPEG to RGB (8-bit per channel) pixels.
2. **Downscale to 40×40** (matching the client's `size = 40` in `ArtworkService.averageColor`, line 122). Any decent box/bilinear downscale is fine; the exact interpolation is not part of the contract, but 40×40 is the target sample grid. If the chosen library cannot resize, an acceptable equivalent is to **average all pixels of the full-resolution image** (see note below).
3. **Average** the R, G, B channels independently across all 1600 sampled pixels (or all pixels if averaging full-res), each channel a mean in `0...255`.
4. **Round** each channel mean to the nearest integer, clamp to `0...255`.
5. **Format** as `"#RRGGBB"` uppercase: `String(format: "#%02X%02X%02X", r, g, b)` — identical to `RGBColor.hexString`.

**Note on 40×40 vs. full-image average:** the client downscales to 40×40 *and then* averages, which is mathematically an (approximate) average of the whole image. A straight average of all full-resolution pixels yields essentially the same mean color and is a valid, simpler implementation if resizing is inconvenient. Either is acceptable for the contract. Prefer the 40×40 path if the library resizes cheaply, since it most closely reproduces the client's prior output; document whichever you choose.

**Alpha:** artwork is JPEG (opaque, no alpha). Ignore alpha. If the decoder yields RGBA, use only R/G/B.

**Determinism requirement:** for a fixed input JPEG and a fixed algorithm choice, the output hex must be deterministic (needed for tests in §9).

**Edge cases:**
- No artwork downloaded (`artworkData == nil`, the `else` branch at `Lambda.swift` line 185–188) → `color = nil` → field omitted.
- Decode failure (corrupt/unsupported JPEG, decoder throws or returns no pixels) → catch it, log, set `color = nil`, **continue** collecting normally (never fail the Lambda invocation because of color). The field is omitted.
- Zero-pixel / degenerate image → treat as decode failure → omit.

**Future enhancement (out of scope):** a true "dominant" color via median-cut or most-frequent quantized bucket is an acceptable later improvement, but the **initial contract is the mean/average** to match the client's existing behavior. Do not implement quantization now.

---

## 6. Implementation Steps (concrete)

### 6.1 Add the JPEG-decode dependency

Add the recommended dependency (see §7) to `Package.swift`:
- Add to the top-level `dependencies:` array.
- Add the product to the **`IcecastMetadataCollector`** target's `dependencies` (the executable target defined around `Package.swift` lines 71–90). It is only needed by the collector.
- Do **not** add it to `Maxi80Lambda` or `Maxi80Backend` unless you implement the optional §6.6 `/artwork` color (which would need it in `Maxi80Lambda`).

### 6.2 Extend `HistoryEntry` (`Sources/IcecastMetadataCollector/HistoryManager.swift`)

Add an optional stored property. Keep synthesized `Codable` if possible — with an optional property, the synthesized encoder **omits** the key when the value is `nil` only if you configure it correctly. **Important:** Swift's *synthesized* `Codable` encodes an `Optional` as JSON `null`, NOT as an omitted key. Since the contract requires **omission** (not `null`), you must implement `encode(to:)` manually to skip nil, OR use `encoder` behavior that drops nil. Concretely:

```swift
struct HistoryEntry: Codable, Sendable, Equatable {
    let artist: String
    let title: String
    let artwork: String
    let timestamp: String
    let color: String?   // "#RRGGBB" uppercase, or nil (omitted from JSON)

    // Memberwise init preserving old call sites: give color a default so existing
    // positional constructions HistoryEntry(artist:title:artwork:timestamp:) still compile.
    init(artist: String, title: String, artwork: String, timestamp: String, color: String? = nil) {
        self.artist = artist
        self.title = title
        self.artwork = artwork
        self.timestamp = timestamp
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case artist, title, artwork, timestamp, color }

    // Decoding: color is optional (decodeIfPresent) so old files without it still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artist = try c.decode(String.self, forKey: .artist)
        title = try c.decode(String.self, forKey: .title)
        artwork = try c.decode(String.self, forKey: .artwork)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    // Encoding: OMIT color when nil (encodeIfPresent), to satisfy the "omit, never null" contract.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(artist, forKey: .artist)
        try c.encode(title, forKey: .title)
        try c.encode(artwork, forKey: .artwork)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(color, forKey: .color)
    }
}
```

Rationale for storing `color` as `String?` (the hex) rather than a typed color value: the collector target has no color type, the value is written verbatim to JSON, and `.sortedKeys` encoding (`writeHistory`, line 49) keeps output stable. Keep it a plain `String`.

Note: the existing memberwise-init default (`color: String? = nil`) keeps every current `HistoryEntry(...)` call site compiling (tests at lines 31–36, 72–77, 132–137, 189–194, 253–258, 327, 339–343, etc.).

### 6.3 Add the color computation helper (`Sources/IcecastMetadataCollector/ArtworkDownloader.swift` or a new file)

Add a method that turns JPEG `Data` into an optional hex string. Make it a member (per project convention: helpers belong to a struct). Suggested: add to `ArtworkDownloader`, or create `DominantColor.swift` with a small struct. Signature:

```swift
/// Returns "#RRGGBB" uppercase mean color, or nil on decode failure / empty image.
func dominantColorHex(fromJPEG data: Data, logger: Logger) -> String?
```

Implementation outline (adapt to the chosen library's API):
1. Try to decode `data` into a pixel buffer. On failure, `logger.warning(...)` and `return nil`.
2. Downscale to 40×40 (or average full-res per §5).
3. Sum R/G/B over all sampled pixels; divide by pixel count; round; clamp `0...255`.
4. `return String(format: "#%02X%02X%02X", r, g, b)`.

Keep it non-throwing (return `nil` on any failure) so the collector never fails an invocation over color.

### 6.4 Thread color into `recordEntry`

`HistoryManager.recordEntry` (lines 56–80) currently builds the entry at line 72:
```swift
let entry = HistoryEntry(artist: artist, title: title, artwork: artworkKey, timestamp: timestamp)
```
Add a `color: String?` parameter (default `nil`) to `recordEntry` and pass it into the `HistoryEntry` initializer:
```swift
func recordEntry(artist: String, title: String, artworkKey: String, timestamp: String, color: String? = nil, logger: Logger) async {
    ...
    let entry = HistoryEntry(artist: artist, title: title, artwork: artworkKey, timestamp: timestamp, color: color)
    ...
}
```
The dedup check at lines 66–70 compares `artist`/`title`/`artwork` only — leave it as-is (color must not affect dedup).

### 6.5 Compute and pass color in the collector (`Sources/IcecastMetadataCollector/Lambda.swift`)

The private helper `recordHistory(artist:title:file:logger:)` (lines 210–214) needs to optionally carry a color. Add a `color: String? = nil` parameter and forward it:
```swift
private func recordHistory(artist: String, title: String, file: String, color: String? = nil, logger: Logger) async {
    let artworkKey = buildS3Key(prefix: s3Writer.config.keyPrefix, artist: artist, title: title, file: file)
    let timestamp = Date.now.formatted(.iso8601)
    await historyManager.recordEntry(artist: artist, title: title, artworkKey: artworkKey, timestamp: timestamp, color: color, logger: logger)
}
```

At the cache-miss path, compute the color from the freshly downloaded `artworkData` (lines 180–205). After the artwork download block, compute:
```swift
let artworkColor: String? = artworkData.flatMap { artworkDownloader.dominantColorHex(fromJPEG: $0, logger: context.logger) }
```
Then update the call at line 205:
```swift
await recordHistory(artist: artist, title: title, file: artworkData != nil ? "artwork.jpg" : "nocover.jpg", color: artworkColor, logger: context.logger)
```

Leave the other `recordHistory` call sites (lines 140, 149, 174) passing `color: nil` (i.e. unchanged — the default covers them). These paths have no in-hand JPEG bytes; per §2.3 do not add S3 fetches to compute color for them in this iteration.

### 6.6 (Optional) `/artwork` response color

Optional, not required by the contract. If desired, `HistoryAction` already exposes color, so a client can look color up from history. If you still want `/artwork` to carry it: `ArtworkAction.handle` (Actions.swift lines 66–97) would need to read the color from history.json (extra S3 read) and add an optional `color: String?` to `ArtworkResponse` (lines 153–159) using `encodeIfPresent`. **Recommendation: skip this** — it duplicates data already in `/history` and adds an S3 read per artwork request. Document that the color is authoritative in `/history`.

---

## 7. Dependencies — recommendation for Linux JPEG decoding

**Constraint recap (§2.7):** Lambda runs on Linux; no CoreGraphics/ImageIO/UIKit/AppKit; `FoundationEssentials` cannot decode JPEG; none of the current deps can either. A dependency is required.

**Recommended: `swift-image` / a pure-Swift or Cinterop JPEG decoder that builds on Linux.** In order of preference:

1. **Preferred — a `libjpeg`/`libjpeg-turbo` system-library interop** via a small SwiftPM `systemLibrary` target or an existing package wrapping it. `libjpeg-turbo` is available in the Amazon Linux 2 / AL2023 Lambda base image or can be bundled in the Lambda layer/container image. This is the most robust decoder for arbitrary Apple Music JPEGs (baseline + progressive). Verify it links in the project's Lambda build/deploy image before committing.
   - If the deploy uses a container image (check the repo's deployment tooling / `README-IcecastMetadataCollector.md`), add `libjpeg-turbo` to the image and a `systemLibrary` target with a `module.modulemap`.
2. **Alternative — a pure-Swift JPEG decoder** such as **`swift-png`'s companion / `jpeg`-in-Swift libraries** (e.g. the pure-Swift `jpeg` package by tayloraswift / `swift-jpeg`). Pros: no system-library or Lambda-image changes, builds anywhere SwiftPM builds, cross-platform, deterministic. Cons: verify it decodes progressive JPEGs (Apple Music sometimes serves progressive) and full-size images within the Lambda's memory/time budget. This is the **lowest-friction** choice and is the recommendation if adding a system library to the Lambda image is undesirable.

**Concrete recommendation:** use the **pure-Swift JPEG decoder (option 2)** unless testing reveals it cannot handle Apple Music's JPEG variants or is too slow; in that case fall back to **`libjpeg-turbo` interop (option 1)**. The pure-Swift route avoids touching the Lambda runtime image and keeps `swift build` / `swift test` working on macOS and Linux identically, which matters for the test suite.

**Documented fallback (no new hard dependency):** if, at implementation time, no suitable decoder can be integrated, the acceptable interim behavior is to **omit `color` entirely** (never emit a bogus value). The client already falls back to its default color when `color` is absent (§3). This keeps the change safe and shippable, but the feature is not delivered — prefer actually integrating a decoder.

Whichever you pick:
- Add it only to the `IcecastMetadataCollector` target (§6.1).
- Confirm it builds for Linux (`swift build` under the Lambda toolchain / container), not just macOS.
- Pin a version with `from:` consistent with the existing `Package.swift` style.

---

## 8. Backward Compatibility & Migration

- **Old entries keep working.** `color` is optional on decode (`decodeIfPresent`, §6.2) and on the client (`decodeIfPresent`, §3). `HistoryManager.readHistory` (lines 37–43) decodes existing `history.json` files unchanged.
- **New writes add `color`** on the cache-miss-with-artwork path; other paths omit it.
- **Existing S3 `history.json` entries will not have `color`** until they are rewritten. That is acceptable — the client falls back to its default background color for entries lacking `color`. Because `history.json` is a rolling window (trimmed to `MAX_HISTORY_SIZE`, `appendAndTrim` lines 26–33), old colorless entries naturally age out as new colored entries are collected.
- **Optional one-off backfill (not required):** a maintenance script/CLI command could read `history.json`, and for each entry whose `artwork` key ends in `artwork.jpg` and lacks `color`, fetch the artwork object from S3 (`S3ManagerProtocol.getObject`, S3Manager.swift line 26/69), compute the hex via the §6.3 helper, set `color`, and write the file back once. If implemented, guard it so it only touches entries missing `color`, and run it manually — do not run it on every invocation. Document it in `README-IcecastMetadataCollector.md` if added. This is explicitly out of scope for the core deliverable.
- **`.sortedKeys` note:** `writeHistory` encodes with `.sortedKeys` (line 49), so `color` will appear alphabetically between `artwork` and `timestamp`... actually after `artwork` and before `timestamp`? Sorted order of keys is `artwork, color, timestamp, title, artist`? No — `.sortedKeys` sorts lexicographically: `artist, artwork, color, timestamp, title`. Key ordering does not affect decoding; do not rely on order.

---

## 9. Testing

Add/adjust tests in `Tests/Maxi80BackendTests/`. Use Swift Testing (`@Test`, `#expect`) consistent with the existing suites.

### 9.1 Color computation (deterministic input → hex)

New unit tests (e.g. in `ArtworkDownloaderTests.swift` or a new `DominantColorTests.swift`):
- **Solid-color image:** construct or embed a tiny known JPEG that is a uniform color (e.g. pure red) and assert `dominantColorHex(fromJPEG:)` returns the expected hex (allowing ±1 per channel to absorb JPEG lossiness / rounding; document the tolerance). If exactness is needed, use a losslessly-representable color or assert within tolerance.
- **Known gradient / two-color image:** assert the returned mean is within tolerance of the analytically expected average.
- **Format assertions:** result matches regex `^#[0-9A-F]{6}$` (leading `#`, uppercase, exactly 6 hex digits).
- Prefer embedding small fixture JPEG bytes inline (base64 in the test) so tests are hermetic and run on Linux (Robolectric/Linux CI) without network.

### 9.2 Decode-failure path

- Feed garbage bytes (`Data([0x00, 0x01, 0x02])`) and empty `Data()` to `dominantColorHex(fromJPEG:)`; assert it returns `nil` and does not throw.

### 9.3 `HistoryEntry` Codable round-trip WITH and WITHOUT `color`

Update `HistoryManagerTests.swift`:
- **Fix Property 2** ("Serialized JSON structure contains required keys", lines 92–107): it currently asserts keys are **exactly** `{artist, title, artwork, timestamp}` (line 100–101). Update so that: when `color == nil` the key set is exactly `{artist, title, artwork, timestamp}` (color omitted), and when `color != nil` the key set is exactly `{artist, title, artwork, timestamp, color}` with `color` a `String`. Add a generated `color` (sometimes nil, sometimes a valid `#RRGGBB`) to the test-case generators.
- **Extend Property 1** ("Serialization round-trip", lines 48–58): include entries with and without `color`; assert `decoded == original` (the `Equatable` conformance now includes `color`).
- **New explicit tests:**
  - Encode an entry with `color = "#3D2A1C"`, decode, assert `color` round-trips and JSON contains `"color":"#3D2A1C"`.
  - Encode an entry with `color = nil`, assert the JSON string does **not** contain `"color"` and does **not** contain `null` for it.
  - Decode a legacy JSON string with no `color` key (e.g. `{"artist":"A","title":"B","artwork":"k","timestamp":"t"}`) and assert it decodes with `color == nil`. This guards backward compatibility.
- Ensure all positional `HistoryEntry(...)` constructions in the test file still compile (they will, given the defaulted `color` param in §6.2).

### 9.4 Full-file compatibility

- Decode a `HistoryFile` JSON where some entries have `color` and some don't (mixed), assert all decode and colored ones retain their hex. This mirrors the real S3 file mid-migration.

### 9.5 Run

- `swift test --filter HistoryManagerTests` and the new decode test target/filter must pass on macOS and (importantly) build on Linux. Also run the full `swift test` to confirm no regressions in `ArtworkActionPropertyTests` etc.

---

## 10. Acceptance Criteria

- [ ] A JPEG-decoding dependency is added to `Package.swift`, wired into the `IcecastMetadataCollector` target only, and **builds on Linux** (verified via the Lambda toolchain/container, not just macOS). If no decoder could be integrated, the documented fallback (omit `color`) is in place and this is noted.
- [ ] `HistoryEntry` has an optional `color: String?` property; its memberwise init defaults `color` to `nil` so existing call sites/tests compile.
- [ ] `HistoryEntry` encoding **omits** `color` when nil (never emits `null`); decoding uses `decodeIfPresent` so legacy entries without `color` decode with `color == nil`.
- [ ] The collector computes the dominant color from downloaded artwork JPEG bytes **only on the cache-miss-with-artwork path** and stores it in the new history entry; other paths write no `color`.
- [ ] The stored/served value is `"#RRGGBB"` uppercase (matches `^#[0-9A-F]{6}$`), computed as the mean R/G/B over a 40×40 downscale (or documented full-image average), rounded and clamped to `0...255`.
- [ ] No-artwork and decode-failure cases omit `color` and never fail the Lambda invocation.
- [ ] Color is computed once at collection time and stored in S3; `/history` continues to serve `history.json` verbatim with no per-request recomputation (`HistoryAction` unchanged).
- [ ] Field name is exactly `color`; the emitted format is byte-for-byte parseable by the client's `RGBColor.parse(hex:)` and ideally equal to `RGBColor.hexString` output.
- [ ] Existing `history.json` entries without `color` still decode and serve unchanged (backward compatibility).
- [ ] Tests added/updated: deterministic color computation (input→hex, with tolerance), decode-failure→nil, `HistoryEntry` Codable round-trip with and without `color`, legacy-decode (no `color` key) test, and the updated Property 2 key-set assertion. `swift test` passes with no regressions.
- [ ] No unrelated behavior changed (dedup logic, trimming, `/station`, `/artwork` URL response all unchanged unless the optional §6.6 was intentionally implemented).
