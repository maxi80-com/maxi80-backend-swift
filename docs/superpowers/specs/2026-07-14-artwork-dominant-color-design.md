# Design: Artwork Dominant Color in `/history`

Date: 2026-07-14
Status: Approved — ready for implementation plan
Supersedes the JPEG-decoding approach in `docs/SPEC-dominant-color.md` §5–§7.

---

## 1. Goal

Add an optional `color` field to each history entry in `history.json` so the
Maxi80 client can paint its background gradient from a server-supplied dominant
color instead of downloading and decoding each artwork JPEG itself.

The client is already implemented and merged (see `docs/SPEC-dominant-color.md`
§3). It decodes an optional `color` string in `"#RRGGBB"` form. This design
only changes the backend collector.

## 2. Key decision: use Apple's `bgColor`, not JPEG decoding

The original spec (`docs/SPEC-dominant-color.md` §5–§7) proposed adding a
Linux-capable JPEG decoder to the collector, downscaling artwork to 40×40, and
averaging pixels to reproduce the client's old computation.

That is unnecessary. The Apple Music search response **already carries a
dominant/background color**:

- `Song.Attributes.Artwork` (`Sources/Maxi80Backend/AppleMusic/AppleMusicModel.swift:120-129`)
  has a **non-optional** `bgColor: String` field (line 124), alongside
  `width`, `height`, `url`, and four `textColor` fields.
- `artwork` itself is `Artwork?` (optional, line 109), but when it is present,
  `bgColor` is guaranteed present too.

Consequence for the fallback: the downloadable JPEG bytes and `bgColor` are
available in **exactly the same situations** (both present iff `artwork != nil`).
A JPEG-decode fallback would therefore be effectively dead code — any time we
had bytes to decode, we already have `bgColor` from the same response. The only
realistic gap is Apple returning a malformed/empty `bgColor` while still serving
artwork; in that rare case we omit `color` (the client falls back to its default
background), which is exactly the spec's documented safe fallback
(`docs/SPEC-dominant-color.md` §7 "Documented fallback").

**Therefore: no new dependency, no Lambda-image change.** Use `bgColor`.

## 3. Contract (unchanged from `docs/SPEC-dominant-color.md` §4)

- Field name: `color` (lowercase, exact).
- Value: JSON string, format `"#RRGGBB"` — leading `#`, then exactly 6
  **uppercase** hex digits. Example `"#3D2A1C"`.
- **Omitted entirely** when no color could be derived. Never `null`, never empty.
- Backward compatible: existing entries without `color` still decode and serve.

Apple's raw `bgColor` is 6 hex digits **without** a leading `#` and of
unspecified case (e.g. `"3d2a1c"`). The collector normalizes it to the contract
format before storing. This matches the client's `RGBColor.parse(hex:)` (accepts
`"#RRGGBB"` or `"RRGGBB"`, 6 digits) and `RGBColor.hexString`
(`String(format: "#%02X%02X%02X", ...)`, uppercase with `#`).

## 4. Components

### 4.1 `HistoryEntry` — add optional `color`
`Sources/IcecastMetadataCollector/HistoryManager.swift`

```swift
struct HistoryEntry: Codable, Sendable, Equatable {
    let artist: String
    let title: String
    let artwork: String
    let timestamp: String
    let color: String?   // "#RRGGBB" uppercase, or nil (omitted from JSON)

    init(artist: String, title: String, artwork: String, timestamp: String, color: String? = nil) {
        self.artist = artist
        self.title = title
        self.artwork = artwork
        self.timestamp = timestamp
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case artist, title, artwork, timestamp, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artist = try c.decode(String.self, forKey: .artist)
        title = try c.decode(String.self, forKey: .title)
        artwork = try c.decode(String.self, forKey: .artwork)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(artist, forKey: .artist)
        try c.encode(title, forKey: .title)
        try c.encode(artwork, forKey: .artwork)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(color, forKey: .color)   // omit when nil
    }
}
```

The defaulted `color` param keeps every existing positional `HistoryEntry(...)`
call site compiling (tests and production).

### 4.2 `DominantColor` — normalize Apple's `bgColor`
New file `Sources/IcecastMetadataCollector/DominantColor.swift`.

```swift
struct DominantColor {
    /// Normalizes Apple Music's `bgColor` into the client contract format.
    /// Returns "#RRGGBB" uppercase, or nil if the input is not exactly 6 hex digits.
    func normalizedHex(fromAppleBgColor raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + s.uppercased()
    }
}
```

Per project convention the helper is a member of a struct (not a free/static
function). Non-throwing; returns `nil` on any malformed input.

### 4.3 `HistoryManager.recordEntry` — thread `color`
`Sources/IcecastMetadataCollector/HistoryManager.swift`

Add `color: String? = nil` and pass it into the `HistoryEntry`. Dedup check
(compares artist/title/artwork only) is unchanged — color must not affect dedup.

```swift
func recordEntry(artist: String, title: String, artworkKey: String, timestamp: String, color: String? = nil, logger: Logger) async {
    ...
    let entry = HistoryEntry(artist: artist, title: title, artwork: artworkKey, timestamp: timestamp, color: color)
    ...
}
```

### 4.4 `Lambda.swift` — derive and pass `color`
`Sources/IcecastMetadataCollector/Lambda.swift`

- `recordHistory` gains `color: String? = nil`, forwarded to `recordEntry`.
- At the cache-miss path (after `selectBestMatch`, around line 205), derive:

```swift
let artworkColor = song.attributes.artwork
    .flatMap { DominantColor().normalizedHex(fromAppleBgColor: $0.bgColor) }
await recordHistory(
    artist: artist, title: title,
    file: artworkData != nil ? "artwork.jpg" : "nocover.jpg",
    color: artworkColor, logger: context.logger
)
```

- The other three `recordHistory` call sites (Maxi 80 house track line 140,
  cache hit line 149, no-results line 174) keep the default `color: nil`
  (unchanged). They have no `Song` in hand, so no `bgColor` to normalize. Cache
  hits will lack color until the entry ages out — acceptable per spec §8.

## 5. Error handling

- `artwork == nil` → `flatMap` yields `nil` → `color` omitted.
- `bgColor` malformed/empty (not 6 hex digits) → `normalizedHex` returns `nil`
  → omitted. Optionally log at `.debug`. Never fails the invocation.
- Cache-hit / house-track / no-results paths → `color: nil` (unchanged).

No path can throw or fail collection because of color.

## 6. Testing

Swift Testing (`@Test`, `#expect`), matching existing suites.

### 6.1 `DominantColorTests.swift` (new)
- `"3d2a1c"` → `"#3D2A1C"` (uppercase, `#` prepended).
- `"#ABCDEF"` → `"#ABCDEF"` (already prefixed, already upper).
- Result matches `^#[0-9A-F]{6}$`.
- Malformed inputs → `nil`: `""`, `"12345"` (5 digits), `"1234567"` (7),
  `"gggggg"` (non-hex), `"  "` (whitespace).

### 6.2 `HistoryManagerTests.swift` (update)
- **Property 2** (JSON key set, lines 92-107): when `color == nil` keys are
  exactly `{artist, title, artwork, timestamp}`; when `color != nil` keys are
  exactly those plus `color` (a String). Add a `color` (sometimes nil, sometimes
  valid `#RRGGBB`) to the generator.
- **Property 1** (round-trip): include entries with and without `color`; assert
  `decoded == original` (Equatable now includes `color`).
- New explicit tests:
  - Encode with `color = "#3D2A1C"` → JSON contains `"color":"#3D2A1C"`,
    round-trips.
  - Encode with `color = nil` → JSON contains neither `"color"` nor `null` for it.
  - Decode legacy JSON `{"artist":"A","title":"B","artwork":"k","timestamp":"t"}`
    → decodes with `color == nil` (backward compat).
- Mixed `HistoryFile` (some entries colored, some not) all decode; colored ones
  retain their hex.

### 6.3 Run
`swift test` — new tests pass, no regressions in existing suites.

## 7. Out of scope

- JPEG decoding / new dependencies (`docs/SPEC-dominant-color.md` §5–§7) — not needed.
- `/artwork` response color (spec §6.6) — skip; `/history` is authoritative.
- Backfill of existing colorless entries — they age out of the rolling window.
- The `BUGS.md` note ("when music search can't find artwork, the entry is not in
  the history") is a separate issue — not addressed here.

## 8. Acceptance criteria

- [ ] `HistoryEntry` has optional `color: String?`; memberwise init defaults it to nil.
- [ ] Encoding omits `color` when nil (never `null`); decoding uses `decodeIfPresent`.
- [ ] Collector derives `color` from `artwork.bgColor` on the cache-miss path,
      normalized to `"#RRGGBB"` uppercase (`^#[0-9A-F]{6}$`); other paths omit it.
- [ ] Malformed/absent `bgColor` omits `color` and never fails the invocation.
- [ ] `/history` (`HistoryAction`) unchanged — serves `history.json` verbatim.
- [ ] Existing colorless entries still decode and serve (backward compat).
- [ ] Tests: `DominantColor` normalization, decode-failure → nil, `HistoryEntry`
      round-trip with/without color, legacy decode, updated Property 2. `swift test` green.
- [ ] No new dependency added to `Package.swift`.
