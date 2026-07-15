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
    let color: String?  // Dominant artwork color "#RRGGBB", or nil (omitted from JSON)

    init(rawMetadata: String, artist: String, title: String, collectedAt: String, color: String? = nil) {
        self.rawMetadata = rawMetadata
        self.artist = artist
        self.title = title
        self.collectedAt = collectedAt
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case rawMetadata, artist, title, collectedAt, color }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawMetadata = try container.decode(String.self, forKey: .rawMetadata)
        artist = try container.decode(String.self, forKey: .artist)
        title = try container.decode(String.self, forKey: .title)
        collectedAt = try container.decode(String.self, forKey: .collectedAt)
        color = try container.decodeIfPresent(String.self, forKey: .color)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawMetadata, forKey: .rawMetadata)
        try container.encode(artist, forKey: .artist)
        try container.encode(title, forKey: .title)
        try container.encode(collectedAt, forKey: .collectedAt)
        try container.encodeIfPresent(color, forKey: .color)
    }
}
