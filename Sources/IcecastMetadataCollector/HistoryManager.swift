import Logging
import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct HistoryEntry: Codable, Sendable, Equatable {
    let artist: String
    let title: String
    let artwork: String  // Full S3 key, e.g. "collected/ArtistName/SongTitle/artwork.jpg"
    let timestamp: String  // ISO 8601 UTC, e.g. "2025-01-15T14:30:00Z"
    let color: String?  // Dominant artwork color as "#RRGGBB" uppercase, or nil (omitted from JSON)

    init(artist: String, title: String, artwork: String, timestamp: String, color: String? = nil) {
        self.artist = artist
        self.title = title
        self.artwork = artwork
        self.timestamp = timestamp
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case artist, title, artwork, timestamp, color }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artist = try container.decode(String.self, forKey: .artist)
        title = try container.decode(String.self, forKey: .title)
        artwork = try container.decode(String.self, forKey: .artwork)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        color = try container.decodeIfPresent(String.self, forKey: .color)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(artist, forKey: .artist)
        try container.encode(title, forKey: .title)
        try container.encode(artwork, forKey: .artwork)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(color, forKey: .color)
    }
}

struct HistoryFile: Codable, Sendable, Equatable {
    var entries: [HistoryEntry]
}

struct HistoryManager {
    let config: S3Config
    let maxHistorySize: Int

    /// Appends an entry to the history and trims oldest entries if count exceeds maxSize.
    static func appendAndTrim(entry: HistoryEntry, to history: HistoryFile, maxSize: Int) -> HistoryFile {
        var entries = history.entries
        entries.append(entry)
        if entries.count > maxSize {
            entries = Array(entries.suffix(maxSize))
        }
        return HistoryFile(entries: entries)
    }

    /// Reads the existing history file from S3. Returns an empty HistoryFile if the file doesn't exist.
    /// Throws on other S3 errors.
    func readHistory() async throws -> HistoryFile {
        let key = "\(config.keyPrefix)/history.json"
        guard let data = try await config.s3Client.getObject(bucket: config.bucket, key: key) else {
            return HistoryFile(entries: [])
        }
        return try JSONDecoder().decode(HistoryFile.self, from: data)
    }

    /// Writes the history file to S3 as JSON with sorted keys.
    func writeHistory(_ history: HistoryFile) async throws {
        let key = "\(config.keyPrefix)/history.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(history)
        try await config.s3Client.putObject(
            data: data,
            bucket: config.bucket,
            key: key,
            contentType: "application/json"
        )
    }

    /// Records a new history entry. Non-throwing — errors are logged internally.
    /// Skips writing if the most recent entry (by timestamp) already matches on artist, title, and artwork.
    func recordEntry(
        artist: String,
        title: String,
        artworkKey: String,
        timestamp: String,
        color: String? = nil,
        logger: Logger
    ) async {
        var history: HistoryFile
        do {
            history = try await readHistory()
        } catch {
            logger.error("Failed to read history: \(error)")
            history = HistoryFile(entries: [])
        }

        // Deduplicate: if the latest entry matches, skip
        if let latest = history.entries.max(by: { $0.timestamp < $1.timestamp }),
            latest.artist == artist, latest.title == title, latest.artwork == artworkKey
        {
            logger.info("Duplicate of latest history entry, skipping")
            return
        }

        let entry = HistoryEntry(artist: artist, title: title, artwork: artworkKey, timestamp: timestamp, color: color)
        let updated = Self.appendAndTrim(entry: entry, to: history, maxSize: maxHistorySize)

        do {
            try await writeHistory(updated)
        } catch {
            logger.error("Failed to write history: \(error)")
        }
    }
}
