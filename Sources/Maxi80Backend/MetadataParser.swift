/// A structure representing metadata for a radio track.
///
/// `TrackMetadata` holds the artist name and title extracted
/// from a raw metadata string, typically received from an audio stream.
public struct TrackMetadata: Sendable {
    /// The name of the artist, or `nil` if it could not be determined.
    public let artist: String?
    /// The title of the track, or `nil` if it could not be determined.
    public let title: String?

    /// Creates a new track metadata instance.
    ///
    /// - Parameters:
    ///   - artist: The artist name, or `nil` if unknown.
    ///   - title: The track title, or `nil` if unknown.
    public init(artist: String?, title: String?) {
        self.artist = artist
        self.title = title
    }
}

/// Parses a raw metadata string into structured track metadata.
///
/// The parser splits the input on dash separators (`" - "` or `"-"`) to
/// extract the artist and title. When no separator is found, the entire
/// input is used as the title with `"Maxi80"` as the default artist.
///
/// The FULL title is preserved (including trailing parentheses such as
/// `(Pretty Young Thing)`) so it is displayed and used as the artwork
/// storage key consistently with the client. Trailing parenthetical
/// content is stripped only when building the Apple Music search query —
/// see ``searchTitle(_:)``.
///
/// - Parameter input: The raw metadata string from the audio stream.
/// - Returns: A ``TrackMetadata`` instance with the parsed artist and title.
public func parseTrackMetadata(_ input: String) -> TrackMetadata {
    let trimmed = input.trimmingWhitespace()

    // Handle empty input
    guard !trimmed.isEmpty else {
        return TrackMetadata(artist: nil, title: nil)
    }

    // Choose the separator. Prefer the spaced " - ": it reliably marks the artist/title
    // boundary and its LAST occurrence keeps multi-artist titles intact
    // (e.g. "Michael Jackson - Diana Ross - Ease On Down The Road").
    //
    // When there is no spaced dash, fall back to a bare "-". Lazily-typed entries such as
    // "modern talking-chery lady" put the artist before the FIRST bare dash, so split there.
    let separator: String
    let separatorIndex: String.Index
    if let spacedRange = trimmed.ranges(of: " - ").last {
        separator = " - "
        separatorIndex = spacedRange.lowerBound
    } else if let bareRange = trimmed.firstRange(of: "-") {
        separator = "-"
        separatorIndex = bareRange.lowerBound
    } else {
        // No separator found — use "Maxi80" as artist and full text as title.
        return TrackMetadata(artist: "Maxi80", title: trimmed)
    }

    let artistPart = String(trimmed[..<separatorIndex]).trimmingWhitespace()
    let titleStartIndex = trimmed.index(separatorIndex, offsetBy: separator.count)
    let titlePart = String(trimmed[titleStartIndex...]).trimmingWhitespace()

    // Handle edge case where separator results in empty parts
    if artistPart.isEmpty && titlePart.isEmpty {
        return TrackMetadata(artist: nil, title: nil)
    }

    // If artist is empty but title exists, use Maxi80 as artist
    let finalArtist = artistPart.isEmpty ? "Maxi80" : normalizeMaxi80Artist(artistPart)
    let finalTitle = titlePart.isEmpty ? nil : titlePart

    return TrackMetadata(
        artist: finalArtist,
        title: finalTitle
    )
}

/// Returns the title with trailing parenthetical content removed, for use as an Apple Music
/// search term. Remix/edit annotations (e.g. `(Radio Edit)`, `(actu 1983)`) reduce match quality,
/// so they are dropped from the query — but NOT from the stored/displayed title.
///
/// - Parameter title: The full track title.
/// - Returns: The title without a trailing `(...)` group, or the original if there is none.
public func searchTitle(_ title: String) -> String {
    removeTrailingParentheses(title)
}

private func removeTrailingParentheses(_ title: String) -> String {
    let trimmed = title.trimmingWhitespace()

    // Check if title ends with parentheses
    if trimmed.hasSuffix(")") {
        if let lastOpenParen = trimmed.lastIndex(of: "(") {
            let beforeParen = String(trimmed[..<lastOpenParen]).trimmingWhitespace()
            return beforeParen.isEmpty ? trimmed : beforeParen
        }
    }

    return trimmed
}

private func normalizeMaxi80Artist(_ artist: String) -> String {
    let lowercased = artist.lowercased()
    if lowercased == "maxi80" || lowercased == "maxi 80" {
        return "Maxi80"
    }
    return artist
}
