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
