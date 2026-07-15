import Foundation
import Testing

@testable import Maxi80Backend

class MockURLSession: URLSessionProtocol {
    var mockData: Data?
    var mockResponse: URLResponse?
    var mockError: (any Error)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let error = mockError {
            throw error
        }

        let data = mockData ?? Data()
        let response =
            mockResponse ?? HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

        return (data, response)
    }
}

@Suite("Maxi80APIClient Tests")
struct Maxi80APIClientTests {

    @Test("Get station returns parsed station data")
    func testGetStation() async throws {
        let mockSession = MockURLSession()
        let stationData = try JSONEncoder().encode(Station.default)
        mockSession.mockData = stationData

        let client = Maxi80APIClient(
            baseURL: URL(string: "https://api.test.com")!,
            apiKey: "test-key",
            session: mockSession
        )

        let station = try await client.getStation()
        #expect(station.name == "Maxi 80")
        #expect(station.streamUrl == "https://audio1.maxi80.com")
    }

    @Test("API client handles HTTP errors")
    func testHTTPError() async {
        let mockSession = MockURLSession()
        mockSession.mockResponse = HTTPURLResponse(
            url: URL(string: "https://api.test.com/station")!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        )

        let client = Maxi80APIClient(
            baseURL: URL(string: "https://api.test.com")!,
            apiKey: "test-key",
            session: mockSession
        )

        do {
            _ = try await client.getStation()
            #expect(Bool(false), "Should have thrown an error")
        } catch {
            if let apiError = error as? APIError {
                #expect(apiError == .httpError(404))
            } else {
                #expect(Bool(false), "Wrong error type")
            }
        }
    }

    @Test("TrackMetadata initialization")
    func testTrackMetadataInitialization() {
        let metadata = TrackMetadata(artist: "Test Artist", title: "Test Title")

        #expect(metadata.artist == "Test Artist")
        #expect(metadata.title == "Test Title")
    }

    @Test("APIError descriptions")
    func testAPIErrorDescriptions() {
        #expect(APIError.invalidURL.errorDescription == "Invalid URL")
        #expect(APIError.invalidResponse.errorDescription == "Invalid response")
        #expect(APIError.httpError(404).errorDescription == "HTTP error: 404")
    }
}
