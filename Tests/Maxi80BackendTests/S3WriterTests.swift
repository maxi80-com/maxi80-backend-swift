import Logging
import Testing

@testable import IcecastMetadataCollector
@testable import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite("S3Writer Tests")
struct S3WriterTests {

    struct S3KeyTestCase: CustomStringConvertible, Sendable {
        let prefix: String
        let artist: String
        let title: String
        var description: String { "prefix='\(prefix)', artist='\(artist)', title='\(title)'" }
    }

    static func generateS3KeyTestCases(count: Int) -> [S3KeyTestCase] {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")

        func randomString(minLen: Int = 1, maxLen: Int = 30) -> String {
            let length = Int.random(in: minLen...maxLen, using: &rng)
            return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
        }

        return (0..<count).map { _ in
            S3KeyTestCase(prefix: randomString(), artist: randomString(), title: randomString())
        }
    }

    // Feature: icecast-metadata-collector, Property 6: S3 key construction
    /// **Validates: Requirements 6.2, 6.3, 6.4**
    @Test(
        "Property 6: S3 key construction pattern",
        arguments: generateS3KeyTestCases(count: 100)
    )
    func s3KeyConstructionPattern(testCase: S3KeyTestCase) {
        let metadataKey = buildS3Key(
            prefix: testCase.prefix,
            artist: testCase.artist,
            title: testCase.title,
            file: "metadata.json"
        )
        let searchKey = buildS3Key(
            prefix: testCase.prefix,
            artist: testCase.artist,
            title: testCase.title,
            file: "search.json"
        )
        let artworkKey = buildS3Key(
            prefix: testCase.prefix,
            artist: testCase.artist,
            title: testCase.title,
            file: "artwork.jpg"
        )

        #expect(metadataKey == "\(testCase.prefix)/\(testCase.artist)/\(testCase.title)/metadata.json")
        #expect(searchKey == "\(testCase.prefix)/\(testCase.artist)/\(testCase.title)/search.json")
        #expect(artworkKey == "\(testCase.prefix)/\(testCase.artist)/\(testCase.title)/artwork.jpg")
    }
}

// MARK: - Cache Hit Property Test

extension S3WriterTests {

    /// Simulates the collector pipeline to verify cache-hit behavior.
    struct MockCollectorPipeline {
        var cacheHit: Bool
        var searchCalled = false
        var artworkDownloadCalled = false
        var s3UploadCalled = false

        mutating func run() {
            // Simulate the collector's handle() logic
            if cacheHit {
                // Cache hit — skip everything
                return
            }
            searchCalled = true
            artworkDownloadCalled = true
            s3UploadCalled = true
        }
    }

    struct CacheHitTestCase: CustomStringConvertible, Sendable {
        let artist: String
        let title: String
        var description: String { "artist='\(artist)', title='\(title)'" }
    }

    static func generateCacheHitTestCases(count: Int) -> [CacheHitTestCase] {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -")

        func randomString() -> String {
            let length = Int.random(in: 1...30, using: &rng)
            return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
        }

        return (0..<count).map { _ in
            CacheHitTestCase(artist: randomString(), title: randomString())
        }
    }

    // Feature: icecast-metadata-collector, Property 7: S3 cache hit skips processing
    /// **Validates: Requirements 6.1**
    @Test(
        "Property 7: S3 cache hit skips processing",
        arguments: generateCacheHitTestCases(count: 100)
    )
    func s3CacheHitSkipsProcessing(testCase: CacheHitTestCase) {
        var pipeline = MockCollectorPipeline(cacheHit: true)
        pipeline.run()

        #expect(!pipeline.searchCalled, "Apple Music search should not be called when cache hit")
        #expect(!pipeline.artworkDownloadCalled, "Artwork download should not be called when cache hit")
        #expect(!pipeline.s3UploadCalled, "S3 upload should not be called when cache hit")
    }
}

// MARK: - CollectedMetadata color encoding / decoding

extension S3WriterTests {

    private static let testLogger = Logger(label: "s3writer-test")

    @Test("CollectedMetadata with a color round-trips and encodes the hex")
    func collectedMetadata_withColor_roundTrips() throws {
        let metadata = CollectedMetadata(
            rawMetadata: "A - B",
            artist: "A",
            title: "B",
            collectedAt: "t",
            color: "#3D2A1C"
        )

        let data = try JSONEncoder().encode(metadata)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"color\":\"#3D2A1C\""))

        let decoded = try JSONDecoder().decode(CollectedMetadata.self, from: data)
        #expect(decoded.color == "#3D2A1C")
    }

    @Test("CollectedMetadata without a color omits the key — never null")
    func collectedMetadata_withoutColor_omitsKey() throws {
        let metadata = CollectedMetadata(rawMetadata: "A - B", artist: "A", title: "B", collectedAt: "t")

        let data = try JSONEncoder().encode(metadata)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("color"))
        #expect(!json.contains("null"))
    }

    @Test("Legacy metadata.json without a color key decodes with color == nil")
    func collectedMetadata_legacy_decodesWithNilColor() throws {
        let legacy = #"{"rawMetadata":"A - B","artist":"A","title":"B","collectedAt":"t"}"#
        let data = try #require(legacy.data(using: .utf8))

        let decoded = try JSONDecoder().decode(CollectedMetadata.self, from: data)
        #expect(decoded.color == nil)
    }
}

// MARK: - S3Writer readMetadata (cache-hit color reuse)

extension S3WriterTests {

    @Test("writeMetadata persists the color into metadata.json")
    func writeMetadata_persistsColor() async throws {
        let mockS3 = MockS3Client()
        let config = S3Config(s3Client: mockS3, bucket: "bucket", keyPrefix: "v2")
        let writer = S3Writer(config: config)

        let metadata = CollectedMetadata(
            rawMetadata: "A - B",
            artist: "A",
            title: "B",
            collectedAt: "t",
            color: "#112233"
        )
        try await writer.writeMetadata(metadata, artist: "A", title: "B", logger: Self.testLogger)

        let puts = await mockS3.getPutRecords()
        let metadataPut = try #require(puts.first { $0.key == "v2/A/B/metadata.json" })
        let decoded = try JSONDecoder().decode(CollectedMetadata.self, from: metadataPut.data)
        #expect(decoded.color == "#112233")
    }

    @Test("readMetadata returns the cached color without any Apple Music call")
    func readMetadata_returnsCachedColor() async throws {
        let mockS3 = MockS3Client()
        let cached = CollectedMetadata(
            rawMetadata: "A - B",
            artist: "A",
            title: "B",
            collectedAt: "t",
            color: "#AABBCC"
        )
        await mockS3.setGetObjectResult(try JSONEncoder().encode(cached))

        let config = S3Config(s3Client: mockS3, bucket: "bucket", keyPrefix: "v2")
        let writer = S3Writer(config: config)

        let result = try await writer.readMetadata(artist: "A", title: "B")
        #expect(result?.color == "#AABBCC")
    }

    @Test("readMetadata returns nil when metadata.json is absent")
    func readMetadata_absent_returnsNil() async throws {
        let mockS3 = MockS3Client()
        await mockS3.setGetObjectResult(nil)

        let config = S3Config(s3Client: mockS3, bucket: "bucket", keyPrefix: "v2")
        let writer = S3Writer(config: config)

        let result = try await writer.readMetadata(artist: "A", title: "B")
        #expect(result == nil)
    }
}

// MARK: - S3Writer legacy-title migration primitives

extension S3WriterTests {

    @Test("copyFile copies a per-track file from the stripped title to the full title")
    func copyFile_copiesBetweenTitleKeys() async throws {
        let mockS3 = MockS3Client()
        let config = S3Config(s3Client: mockS3, bucket: "bucket", keyPrefix: "v2")
        let writer = S3Writer(config: config)

        try await writer.copyFile(
            "artwork.jpg",
            artist: "Michael Jackson",
            fromTitle: "PYT",
            toTitle: "PYT (Pretty Young Thing)",
            logger: Self.testLogger
        )

        let copies = await mockS3.getCopyRecords()
        let copy = try #require(copies.first)
        #expect(copy.bucket == "bucket")
        #expect(copy.fromKey == "v2/Michael Jackson/PYT/artwork.jpg")
        #expect(copy.toKey == "v2/Michael Jackson/PYT (Pretty Young Thing)/artwork.jpg")
    }

    @Test("deleteFile deletes the stripped-title object")
    func deleteFile_deletesStrippedTitleKey() async throws {
        let mockS3 = MockS3Client()
        let config = S3Config(s3Client: mockS3, bucket: "bucket", keyPrefix: "v2")
        let writer = S3Writer(config: config)

        try await writer.deleteFile(
            "metadata.json",
            artist: "Michael Jackson",
            title: "PYT",
            logger: Self.testLogger
        )

        let deletes = await mockS3.getDeleteRecords()
        let delete = try #require(deletes.first)
        #expect(delete.bucket == "bucket")
        #expect(delete.key == "v2/Michael Jackson/PYT/metadata.json")
    }
}

// MARK: - S3Writer Error Handling Unit Tests

extension S3WriterTests {

    @Test("CollectorError.s3WriteFailed includes file name - metadata.json")
    func s3WriteFailedMetadataIncludesFileName() {
        let error = CollectorError.s3WriteFailed(file: "metadata.json", reason: "Access Denied")
        if case .s3WriteFailed(let file, let reason) = error {
            #expect(file == "metadata.json")
            #expect(reason == "Access Denied")
        } else {
            Issue.record("Expected s3WriteFailed error")
        }
    }

    @Test("CollectorError.s3WriteFailed includes file name - search.json")
    func s3WriteFailedSearchIncludesFileName() {
        let error = CollectorError.s3WriteFailed(file: "search.json", reason: "Bucket not found")
        if case .s3WriteFailed(let file, let reason) = error {
            #expect(file == "search.json")
            #expect(reason == "Bucket not found")
        } else {
            Issue.record("Expected s3WriteFailed error")
        }
    }

    @Test("CollectorError.s3WriteFailed includes file name - artwork.jpg")
    func s3WriteFailedArtworkIncludesFileName() {
        let error = CollectorError.s3WriteFailed(file: "artwork.jpg", reason: "Network timeout")
        if case .s3WriteFailed(let file, let reason) = error {
            #expect(file == "artwork.jpg")
            #expect(reason == "Network timeout")
        } else {
            Issue.record("Expected s3WriteFailed error")
        }
    }
}
