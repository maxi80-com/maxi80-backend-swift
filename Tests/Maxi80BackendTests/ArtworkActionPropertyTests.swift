import AWSLambdaEvents
import Foundation
import Logging
import Testing

@testable import Maxi80Lambda

// MARK: - Helpers

private func randomNonEmptyString() -> String {
    let length = Int.random(in: 1...50)
    let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_"
    return String((0..<length).map { _ in chars.randomElement()! })
}

private let testLogger = Logger(label: "test")

private func makeArtworkAction(
    s3Client: MockS3Client,
    bucket: String = "test-bucket",
    keyPrefix: String = "v2",
    urlExpiration: TimeInterval = 3600
) -> ArtworkAction {
    ArtworkAction(
        s3Client: s3Client,
        bucket: bucket,
        keyPrefix: keyPrefix,
        urlExpiration: urlExpiration
    )
}

private func makeEvent(artist: String, title: String) throws -> APIGatewayV2Request {
    try TestHelpers.createAPIGatewayRequest(
        path: "/artwork",
        queryStringParameters: ["artist": artist, "title": title]
    )
}

// MARK: - Property Tests

@Suite("ArtworkAction Property Tests")
struct ArtworkActionPropertyTests {

    // Feature: replace-search-with-image-endpoint, Property 1: S3 key construction
    @Test("Property 1: S3 key is {keyPrefix}/{artist}/{title}/artwork.jpg for random inputs")
    func s3KeyConstruction() async throws {
        // Validates: Requirements 2.1, 3.3
        let iterations = 100
        for _ in 0..<iterations {
            let artist = randomNonEmptyString()
            let title = randomNonEmptyString()
            let keyPrefix = randomNonEmptyString()

            let mockS3 = MockS3Client()
            await mockS3.setExists(true)
            await mockS3.setPresignedURL("https://example.com/art")

            let action = makeArtworkAction(s3Client: mockS3, keyPrefix: keyPrefix)
            let event = try makeEvent(artist: artist, title: title)

            _ = try await action.handle(event: event, logger: testLogger)

            let records = await mockS3.getCallRecords()
            #expect(records.count == 1)
            let expectedKey = "\(keyPrefix)/\(artist)/\(title)/artwork.jpg"
            #expect(records[0].key == expectedKey)
        }
    }

    // Feature: replace-search-with-image-endpoint, Property 2: Artwork exists returns JSON with pre-signed URL
    @Test("Property 2: When artwork exists, response decodes to ArtworkResponse with non-empty url")
    func artworkExistsReturnsJSON() async throws {
        // Validates: Requirements 2.2, 3.1, 3.2
        let iterations = 100
        for _ in 0..<iterations {
            let artist = randomNonEmptyString()
            let title = randomNonEmptyString()

            let mockS3 = MockS3Client()
            await mockS3.setExists(true)
            let expectedURL = "https://s3.example.com/\(randomNonEmptyString())"
            await mockS3.setPresignedURL(expectedURL)

            let action = makeArtworkAction(s3Client: mockS3)
            let event = try makeEvent(artist: artist, title: title)

            let data = try await action.handle(event: event, logger: testLogger)
            #expect(!data.isEmpty)

            let response = try JSONDecoder().decode(ArtworkResponse.self, from: data)
            #expect(!response.url.absoluteString.isEmpty)
        }
    }

    // Feature: replace-search-with-image-endpoint, Property 3: Artwork not found returns empty response
    @Test("Property 3: When artwork does not exist, response is empty Data")
    func artworkNotFoundReturnsEmpty() async throws {
        // Validates: Requirements 2.3, 3.5
        let iterations = 100
        for _ in 0..<iterations {
            let artist = randomNonEmptyString()
            let title = randomNonEmptyString()

            let mockS3 = MockS3Client()
            await mockS3.setExists(false)

            let action = makeArtworkAction(s3Client: mockS3)
            let event = try makeEvent(artist: artist, title: title)

            let data = try await action.handle(event: event, logger: testLogger)
            #expect(data.isEmpty)
        }
    }

    // Feature: replace-search-with-image-endpoint, Property 4: Pre-signed URL uses configured expiration
    @Test("Property 4: Pre-signed URL expiration matches configured value for random expirations")
    func presignedURLUsesConfiguredExpiration() async throws {
        // Validates: Requirements 3.4
        let iterations = 100
        for _ in 0..<iterations {
            let expiration = TimeInterval(Int.random(in: 1...86400))

            let mockS3 = MockS3Client()
            await mockS3.setExists(true)
            await mockS3.setPresignedURL("https://example.com/art")

            let action = makeArtworkAction(s3Client: mockS3, urlExpiration: expiration)
            let event = try makeEvent(artist: randomNonEmptyString(), title: randomNonEmptyString())

            _ = try await action.handle(event: event, logger: testLogger)

            let expirations = await mockS3.getPresignExpirations()
            #expect(expirations.count == 1)
            #expect(expirations[0] == expiration)
        }
    }

    // Feature: replace-search-with-image-endpoint, Property 7: S3 errors propagate as internal server error
    @Test("Property 7: Non-NotFound S3 errors propagate as thrown errors")
    func s3ErrorsPropagate() async throws {
        // Validates: Requirements 6.1
        let iterations = 100
        for _ in 0..<iterations {
            let mockS3 = MockS3Client()
            await mockS3.setError(
                NSError(
                    domain: "S3Error",
                    code: Int.random(in: 1...999),
                    userInfo: [NSLocalizedDescriptionKey: randomNonEmptyString()]
                )
            )

            let action = makeArtworkAction(s3Client: mockS3)
            let event = try makeEvent(artist: randomNonEmptyString(), title: randomNonEmptyString())

            await #expect(throws: (any Error).self) {
                _ = try await action.handle(event: event, logger: testLogger)
            }
        }
    }
}
