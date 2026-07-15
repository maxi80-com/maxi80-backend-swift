#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

    // Handle empty input
    guard !trimmed.isEmpty else {
        return TrackMetadata(artist: nil, title: nil)
    }

    // Check for separators - prioritize " - " over "-"
    let dashSeparators = [" - ", "-"]
    var bestSeparator: String?
    var lastSeparatorIndex: String.Index?

    // Find the last occurrence of " - " first, then "-"
    for separator in dashSeparators {
        if let range = trimmed.range(of: separator, options: .backwards) {
            // For single dash, make sure it's not part of a word (has spaces or is at boundaries)
            if separator == "-" {
                let beforeIndex = range.lowerBound
                let afterIndex = range.upperBound
                let hasSpaceBefore =
                    beforeIndex == trimmed.startIndex || trimmed[trimmed.index(before: beforeIndex)] == " "
                let hasSpaceAfter = afterIndex == trimmed.endIndex || trimmed[afterIndex] == " "

                // Only treat as separator if it has space on at least one side or is at boundaries
                if hasSpaceBefore || hasSpaceAfter {
                    if lastSeparatorIndex == nil || range.lowerBound > lastSeparatorIndex! {
                        lastSeparatorIndex = range.lowerBound
                        bestSeparator = separator
                    }
                }
            } else {
                // " - " is always a valid separator
                if lastSeparatorIndex == nil || range.lowerBound > lastSeparatorIndex! {
                    lastSeparatorIndex = range.lowerBound
                    bestSeparator = separator
                }
            }
        }
    }

    // If no separator found, use "Maxi80" as artist and full text as title
    guard let separatorIndex = lastSeparatorIndex, let separator = bestSeparator else {
        return TrackMetadata(artist: "Maxi80", title: trimmed)
    }

    let artistPart = String(trimmed[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    let titleStartIndex = trimmed.index(separatorIndex, offsetBy: separator.count)
    let titlePart = String(trimmed[titleStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

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
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

    // Check if title ends with parentheses
    if trimmed.hasSuffix(")") {
        if let lastOpenParen = trimmed.lastIndex(of: "(") {
            let beforeParen = String(trimmed[..<lastOpenParen]).trimmingCharacters(in: .whitespacesAndNewlines)
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
