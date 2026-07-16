import AWSLambdaEvents
import Foundation
import HTTPTypes
import Logging
import Routing
import Testing

@testable import Maxi80Backend
@testable import Maxi80Lambda

@Suite("Lambda Handler Tests")
struct LambdaHandlerTests {

    @Test("Lambda initialization with mock S3 client succeeds")
    func testLambdaInitialization() async throws {
        let mockS3Client = MockS3Client()
        let lambda = try await Maxi80Lambda(s3Client: mockS3Client)
        _ = lambda
    }

    @Test("Station action returns the default station as JSON")
    func testStationAction() async throws {
        let response = try await StationAction().handle(
            TestHelpers.createHTTPRequest(path: "/station"),
            Logger(label: "test")
        )

        #expect(response.statusCode == .ok)
        let station = try JSONDecoder().decode(Station.self, from: TestHelpers.body(of: response))
        #expect(station.name == "Maxi 80")
        #expect(station.streamUrl == "https://audio1.maxi80.com")
    }

    @Test("History action returns empty entries when no history file exists")
    func testHistoryActionEmpty() async throws {
        let mockS3 = MockS3Client()
        let action = HistoryAction(s3Client: mockS3, bucket: "test-bucket", keyPrefix: "v2")

        let response = try await action.handle(
            TestHelpers.createHTTPRequest(path: "/history"),
            Logger(label: "test")
        )

        #expect(response.statusCode == .ok)
        let body = String(decoding: try TestHelpers.body(of: response), as: UTF8.self)
        #expect(body == "{\"entries\":[]}")
    }

    @Test("History action returns the stored history file verbatim")
    func testHistoryActionReturnsStored() async throws {
        let mockS3 = MockS3Client()
        let stored = "{\"entries\":[{\"artist\":\"Duran Duran\",\"title\":\"Rio\"}]}"
        await mockS3.setGetObjectResult(Data(stored.utf8))
        let action = HistoryAction(s3Client: mockS3, bucket: "test-bucket", keyPrefix: "v2")

        let response = try await action.handle(
            TestHelpers.createHTTPRequest(path: "/history"),
            Logger(label: "test")
        )

        #expect(response.statusCode == .ok)
        let body = String(decoding: try TestHelpers.body(of: response), as: UTF8.self)
        #expect(body == stored)
    }
}
