import AsyncHTTPClient
import Foundation
import NIOHTTP1
import Testing

@testable import Maxi80Backend

@Suite("HTTP Client Tests")
struct HTTPClientTests {

    @Test("MusicAPIClient request building")
    func testRequestBuilding() {
        // Given
        let client = MusicAPIClient()
        let url = URL(string: "https://api.music.apple.com/v1/test")!
        let headers = ["Authorization": "Bearer token", "Custom-Header": "value"]
        let body = "test body".data(using: .utf8)

        // When
        let request = client.request(
            for: url,
            method: .POST,
            withBody: body,
            withHeaders: headers
        )

        // Then
        #expect(request.method == .POST)
        #expect(request.url == "https://api.music.apple.com/v1/test")

        // Check only the headers that were passed (request method doesn't add standard headers)
        #expect(request.headers.first(name: "Authorization") == "Bearer token")
        #expect(request.headers.first(name: "Custom-Header") == "value")

        // Standard headers are not added by request() method, only by apiCall()
        #expect(request.headers.first(name: "Content-Type") == nil)
        #expect(request.headers.first(name: "Accept") == nil)
        #expect(request.headers.first(name: "User-Agent") == nil)

        // Check body
        #expect(request.body != nil)
    }

    @Test("MusicAPIClient request building with no body")
    func testRequestBuildingNoBody() {
        // Given
        let client = MusicAPIClient()
        let url = URL(string: "https://api.music.apple.com/v1/test")!

        // When
        let request = client.request(for: url, method: .GET)

        // Then
        #expect(request.method == .GET)
        #expect(request.url == "https://api.music.apple.com/v1/test")
        #expect(request.body == nil)

        // No headers should be set when none are provided to request method
        #expect(request.headers.first(name: "Content-Type") == nil)
        #expect(request.headers.first(name: "Accept") == nil)
        #expect(request.headers.first(name: "User-Agent") == nil)
    }

    @Test("MusicAPIClient header merging")
    func testHeaderMerging() {
        // Given
        let client = MusicAPIClient()
        let url = URL(string: "https://api.music.apple.com/v1/test")!

        // Headers that override defaults
        let headers = [
            "Content-Type": "application/xml",  // Override default
            "Authorization": "Bearer token",  // New header
        ]

        // When
        let request = client.request(for: url, withHeaders: headers)

        // Then - Only the headers that were explicitly passed should be present
        #expect(request.headers.first(name: "Content-Type") == "application/xml")  // Passed header
        #expect(request.headers.first(name: "Authorization") == "Bearer token")  // Passed header

        // Standard headers are not added by request() method, only by apiCall()
        #expect(request.headers.first(name: "Accept") == nil)
        #expect(request.headers.first(name: "User-Agent") == nil)
    }
}
