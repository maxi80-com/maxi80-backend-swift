import Foundation
import Logging
import NIOHTTP1
import Testing

@testable import IcecastMetadataCollector
@testable import Maxi80Backend

@Suite("MetadataCollector Pipeline Tests")
struct MetadataCollectorTests {

    static let logger = Logger(label: "collector-test")
    static let bucket = "bucket"
    static let prefix = "v2"

    /// Assembles a collector backed by the shared S3 mock plus fakes for the network dependencies.
    static func makeCollector(
        rawMetadata: String,
        s3: MockS3Client,
        http: MockHTTPClient = MockHTTPClient(),
        artwork: FakeArtworkDownloader = FakeArtworkDownloader(),
        maxHistorySize: Int = 100
    ) -> MetadataCollector {
        let config = S3Config(s3Client: s3, bucket: bucket, keyPrefix: prefix)
        return MetadataCollector(
            streamURL: "https://stream.example",
            authProvider: FakeAuthProvider(),
            httpClient: http,
            s3Writer: S3Writer(config: config),
            icecastReader: FakeIcecastReader(rawMetadata: rawMetadata),
            artworkDownloader: artwork,
            historyManager: HistoryManager(config: config, maxHistorySize: maxHistorySize)
        )
    }

    static func metadataJSON(rawMetadata: String, artist: String, title: String, color: String?) -> Data {
        let m = CollectedMetadata(
            rawMetadata: rawMetadata,
            artist: artist,
            title: title,
            collectedAt: "t",
            color: color
        )
        return try! JSONEncoder().encode(m)
    }

    // MARK: - The P.Y.T. bug: legacy stripped-title cache migrates to the full title

    @Test("Legacy stripped-title cache is migrated to the full-title key")
    func migratesStrippedTitleToFullTitle() async throws {
        let s3 = MockS3Client()
        let artist = "Michael Jackson"
        let full = "PYT (Pretty Young Thing)"
        let stripped = "PYT"

        // Existing objects live under the STRIPPED title (as the old parser stored them).
        await s3.setObject(
            key: "\(Self.prefix)/\(artist)/\(stripped)/metadata.json",
            data: Self.metadataJSON(
                rawMetadata: "\(artist) - \(full)",
                artist: artist,
                title: stripped,
                color: "#0D0F11"
            )
        )
        await s3.setObject(key: "\(Self.prefix)/\(artist)/\(stripped)/artwork.jpg", data: Data("img".utf8))
        await s3.setObject(key: "\(Self.prefix)/\(artist)/\(stripped)/search.json", data: Data("{}".utf8))

        let collector = Self.makeCollector(rawMetadata: "\(artist) - \(full)", s3: s3)
        try await collector.collect(logger: Self.logger)

        // Copied every file from stripped → full.
        let copies = await s3.getCopyRecords()
        #expect(
            copies.contains {
                $0.fromKey.hasSuffix("/\(stripped)/artwork.jpg") && $0.toKey.hasSuffix("/\(full)/artwork.jpg")
            }
        )
        #expect(
            copies.contains {
                $0.fromKey.hasSuffix("/\(stripped)/metadata.json") && $0.toKey.hasSuffix("/\(full)/metadata.json")
            }
        )
        #expect(
            copies.contains {
                $0.fromKey.hasSuffix("/\(stripped)/search.json") && $0.toKey.hasSuffix("/\(full)/search.json")
            }
        )

        // Rewrote metadata.json under the full title, carrying the color and preserving rawMetadata.
        let puts = await s3.getPutRecords()
        let metaPut = try #require(puts.first { $0.key == "\(Self.prefix)/\(artist)/\(full)/metadata.json" })
        let migrated = try JSONDecoder().decode(CollectedMetadata.self, from: metaPut.data)
        #expect(migrated.title == full)
        #expect(migrated.color == "#0D0F11")

        // Deleted the old stripped-title originals to avoid orphaned storage.
        let deletes = await s3.getDeleteRecords()
        #expect(deletes.contains { $0.key == "\(Self.prefix)/\(artist)/\(stripped)/artwork.jpg" })
        #expect(deletes.contains { $0.key == "\(Self.prefix)/\(artist)/\(stripped)/metadata.json" })
        #expect(deletes.contains { $0.key == "\(Self.prefix)/\(artist)/\(stripped)/search.json" })

        // History recorded under the FULL title with an artwork key.
        let historyData = try #require(await s3.getObject(bucket: Self.bucket, key: "\(Self.prefix)/history.json"))
        let history = try JSONDecoder().decode(HistoryFile.self, from: historyData)
        let entry = try #require(history.entries.last)
        #expect(entry.title == full)
        #expect(entry.artwork == "\(Self.prefix)/\(artist)/\(full)/artwork.jpg")
        #expect(entry.color == "#0D0F11")
    }

    @Test("Full-title cache hit does not trigger migration")
    func fullTitleCacheHitNoMigration() async throws {
        let s3 = MockS3Client()
        let artist = "Michael Jackson"
        let full = "PYT (Pretty Young Thing)"

        // Object already exists under the FULL title.
        await s3.setObject(
            key: "\(Self.prefix)/\(artist)/\(full)/metadata.json",
            data: Self.metadataJSON(rawMetadata: "\(artist) - \(full)", artist: artist, title: full, color: "#0D0F11")
        )

        let collector = Self.makeCollector(rawMetadata: "\(artist) - \(full)", s3: s3)
        try await collector.collect(logger: Self.logger)

        let copies = await s3.getCopyRecords()
        let deletes = await s3.getDeleteRecords()
        #expect(copies.isEmpty)
        #expect(deletes.isEmpty)
    }

    // MARK: - Fresh collection stores the full title, searches with the stripped title

    @Test("Fresh collection stores the FULL title and queries Apple Music with the STRIPPED title")
    func freshCollectionStoresFullTitleSearchesStripped() async throws {
        let s3 = MockS3Client()  // keyed mode off → all getObject return nil (no cache, no legacy)
        let artist = "Michael Jackson"
        let full = "PYT (Pretty Young Thing)"

        let http = MockHTTPClient()
        await http.setResponse(data: Self.appleMusicResponseWithArtwork(), status: .ok)

        let collector = Self.makeCollector(rawMetadata: "\(artist) - \(full)", s3: s3, http: http)
        try await collector.collect(logger: Self.logger)

        // The search term drops the trailing parentheses.
        let calls = await http.getCallRecords()
        let searchCall = try #require(calls.first)
        let query = searchCall.url.absoluteString.removingPercentEncoding ?? searchCall.url.absoluteString
        #expect(query.contains("PYT"))
        #expect(!query.contains("Pretty Young Thing"))

        // Stored objects use the FULL title as the key.
        let puts = await s3.getPutRecords()
        #expect(puts.contains { $0.key == "\(Self.prefix)/\(artist)/\(full)/metadata.json" })
        #expect(puts.contains { $0.key == "\(Self.prefix)/\(artist)/\(full)/artwork.jpg" })
    }

    static func appleMusicResponseWithArtwork() -> Data {
        // Reuse the full, decodable fixture from SongSelectorTests (one song with artwork).
        Data(SongSelectorTests.searchResponseJSON(songIDs: ["1"]).utf8)
    }

    // MARK: - Resilience: a track always lands in history, even when enrichment fails

    struct FakeS3Error: Error {}

    /// The entries in the most recent history.json write (via getPutRecords, which works in the
    /// mock's default non-keyed mode — unlike reading getObject back). Empty if never written.
    static func lastWrittenHistoryEntries(_ s3: MockS3Client) async throws -> [HistoryEntry] {
        let puts = await s3.getPutRecords()
        guard let historyPut = puts.last(where: { $0.key == "\(prefix)/history.json" }) else {
            return []
        }
        return try JSONDecoder().decode(HistoryFile.self, from: historyPut.data).entries
    }

    @Test("Cache-read failure still records the track with a no-cover placeholder")
    func cacheReadFailureStillRecordsHistory() async throws {
        // Reproduces the Yazoo "Don't go (maxi)" incident: the S3 cache read throws for a
        // cache-miss key. The track must still be recorded (nocover.jpg) rather than vanishing.
        let s3 = MockS3Client()
        await s3.setGetObjectMissError(FakeS3Error())

        let collector = Self.makeCollector(rawMetadata: "Yazoo - Don't go (maxi)", s3: s3)
        try await collector.collect(logger: Self.logger)

        let entries = try await Self.lastWrittenHistoryEntries(s3)
        let entry = try #require(entries.last)
        #expect(entry.artist == "Yazoo")
        #expect(entry.title == "Don't go (maxi)")
        #expect(entry.artwork == "\(Self.prefix)/Yazoo/Don't go (maxi)/nocover.jpg")
    }

    @Test("Apple Music search failure still records the track with a no-cover placeholder")
    func searchFailureStillRecordsHistory() async throws {
        // Cache miss (default mode → all getObject return nil), then the Apple Music HTTP call throws.
        let s3 = MockS3Client()
        let http = MockHTTPClient()
        await http.setError(FakeS3Error())

        let collector = Self.makeCollector(rawMetadata: "The Cure - Boys don't cry", s3: s3, http: http)
        try await collector.collect(logger: Self.logger)

        let entries = try await Self.lastWrittenHistoryEntries(s3)
        let entry = try #require(entries.last)
        #expect(entry.artist == "The Cure")
        #expect(entry.title == "Boys don't cry")
        #expect(entry.artwork.hasSuffix("/nocover.jpg"))
    }

    @Test("Successful cache-miss collection records exactly one history entry")
    func freshCollectionRecordsExactlyOnce() async throws {
        let s3 = MockS3Client()  // keyed mode off → getObject returns nil (no cache, no legacy)
        let http = MockHTTPClient()
        await http.setResponse(data: Self.appleMusicResponseWithArtwork(), status: .ok)

        let collector = Self.makeCollector(rawMetadata: "Michael Jackson - Beat it", s3: s3, http: http)
        try await collector.collect(logger: Self.logger)

        let entries = try await Self.lastWrittenHistoryEntries(s3)
        #expect(entries.count == 1)
        #expect(entries.last?.artwork.hasSuffix("/artwork.jpg") == true)
    }
}
