import AWSLambdaEvents
import Foundation
import HTTPTypes
import Logging
import Routing
import Testing

@testable import Maxi80Backend
@testable import Maxi80Lambda

/// End-to-end routing tests that drive the built `Maxi80Router` the same way the
/// Lambda entry point does, exercising the real lambda-kit dispatch (method +
/// path matching, 404/400 fallbacks).
@Suite("Maxi80Router Integration Tests")
struct Maxi80RouterTests {

    private let logger = Logger(label: "test")

    private func makeRouter(s3: MockS3Client = MockS3Client()) -> Maxi80Router {
        Maxi80Router(
            station: StationAction(),
            artwork: ArtworkAction(
                s3Client: s3,
                bucket: "test-bucket",
                keyPrefix: "v2",
                urlExpiration: 3600
            ),
            history: HistoryAction(s3Client: s3, bucket: "test-bucket", keyPrefix: "v2")
        )
    }

    @Test("GET /station returns 200 with the default station")
    func stationRoute() async throws {
        let request = try TestHelpers.createHTTPRequest(path: "/station")
        let response = await makeRouter().handle(request, logger: logger)

        #expect(response.statusCode == .ok)
        let body = try #require(response.body)
        let station = try JSONDecoder().decode(Station.self, from: Data(body.utf8))
        #expect(station.name == "Maxi 80")
    }

    @Test("GET /artwork with both parameters returns 200 with a presigned URL")
    func artworkRouteExists() async throws {
        let s3 = MockS3Client()
        await s3.setExists(true)
        await s3.setPresignedURL("https://s3.example.com/art.jpg")

        let request = try TestHelpers.createHTTPRequest(
            path: "/artwork",
            queryStringParameters: ["artist": "Duran Duran", "title": "Rio"]
        )
        let response = await makeRouter(s3: s3).handle(request, logger: logger)

        #expect(response.statusCode == .ok)
        let body = try #require(response.body)
        let decoded = try JSONDecoder().decode(ArtworkResponse.self, from: Data(body.utf8))
        #expect(decoded.url.absoluteString == "https://s3.example.com/art.jpg")
    }

    @Test("GET /artwork missing a parameter returns 400")
    func artworkRouteMissingParameter() async throws {
        let request = try TestHelpers.createHTTPRequest(path: "/artwork")
        let response = await makeRouter().handle(request, logger: logger)

        #expect(response.statusCode == .badRequest)
    }

    @Test("GET /history with no stored file returns 200 with empty entries")
    func historyRouteEmpty() async throws {
        let request = try TestHelpers.createHTTPRequest(path: "/history")
        let response = await makeRouter().handle(request, logger: logger)

        #expect(response.statusCode == .ok)
        #expect(response.body == "{\"entries\":[]}")
    }

    @Test("Unknown path returns 404")
    func unknownPath() async throws {
        let request = try TestHelpers.createHTTPRequest(path: "/does-not-exist")
        let response = await makeRouter().handle(request, logger: logger)

        #expect(response.statusCode == .notFound)
    }

    @Test("Known path with unsupported method returns 404")
    func unsupportedMethod() async throws {
        let request = try TestHelpers.createHTTPRequest(path: "/station", httpMethod: "POST")
        let response = await makeRouter().handle(request, logger: logger)

        #expect(response.statusCode == .notFound)
    }
}
