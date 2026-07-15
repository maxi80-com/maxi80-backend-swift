import Foundation
import Testing

@testable import IcecastMetadataCollector
@testable import Maxi80Backend

@Suite("Song Selector Tests")
struct SongSelectorTests {

    // MARK: - JSON Helpers

    /// Builds a minimal Song JSON string with a given id.
    static func songJSON(id: String) -> String {
        """
        {
            "id": "\(id)",
            "type": "songs",
            "href": "/v1/catalog/fr/songs/\(id)",
            "attributes": {
                "albumName": "Test Album",
                "artistName": "Test Artist",
                "genreNames": ["Pop"],
                "trackNumber": 1,
                "durationInMillis": 200000,
                "releaseDate": "1985-01-01",
                "isrc": "USTEST000001",
                "artwork": {
                    "width": 3000,
                    "height": 3000,
                    "url": "https://example.com/{w}x{h}bb.jpg",
                    "bgColor": "000000",
                    "textColor1": "ffffff",
                    "textColor2": "cccccc",
                    "textColor3": "999999",
                    "textColor4": "666666"
                },
                "composerName": "Test Composer",
                "url": "https://music.apple.com/fr/song/\(id)",
                "playParams": {
                    "id": "\(id)",
                    "kind": "song"
                },
                "discNumber": 1,
                "hasCredits": true,
                "hasLyrics": false,
                "isAppleDigitalMaster": false,
                "name": "Song \(id)",
                "previews": [{"url": "https://example.com/preview.m4a"}]
            }
        }
        """
    }

    /// Builds a full AppleMusicSearchResponse JSON with the given song IDs.
    static func searchResponseJSON(songIDs: [String]) -> String {
        let songsJSON = songIDs.map { songJSON(id: $0) }.joined(separator: ",")
        let songsSection: String
        if songIDs.isEmpty {
            songsSection = ""
        } else {
            songsSection = """
                "songs": {
                    "data": [\(songsJSON)],
                    "href": "/v1/catalog/fr/search?types=songs",
                    "next": null
                }
                """
        }
        return """
            {
                "meta": {
                    "results": {
                        "order": ["songs"],
                        "rawOrder": ["songs"]
                    }
                },
                "results": {
                    \(songsSection)
                }
            }
            """
    }

    /// Decodes an AppleMusicSearchResponse from a list of song IDs.
    static func decodeResponse(songIDs: [String]) throws -> AppleMusicSearchResponse {
        let json = searchResponseJSON(songIDs: songIDs)
        return try JSONDecoder().decode(AppleMusicSearchResponse.self, from: json.data(using: .utf8)!)
    }

    // MARK: - Test Case Generators

    /// Generates 100 test cases with varying song counts (1–20), each repeated 5 times.
    static func generateSongCountTestCases() -> [Int] {
        Array(1...20) + Array(1...20) + Array(1...20) + Array(1...20) + Array(1...20)
    }

    // MARK: - Property Tests

    // Feature: icecast-metadata-collector, Property 4: Song selector returns first element
    /// **Validates: Requirements 4.1**
    @Test(
        "Property 4: Song selector returns first element",
        arguments: generateSongCountTestCases()
    )
    func songSelectorReturnsFirst(songCount: Int) throws {
        let ids = (0..<songCount).map { "song-\($0)-\(Int.random(in: 1000...9999))" }
        let response = try SongSelectorTests.decodeResponse(songIDs: ids)
        let result = selectBestMatch(response)
        #expect(result != nil, "selectBestMatch should return a song for non-empty results")
        #expect(result?.id == ids.first, "selectBestMatch should return the first song (id: \(ids.first ?? "nil"))")
    }

    // MARK: - Unit Tests

    @Test("Song selector returns nil for empty results")
    func songSelectorReturnsNilForEmpty() throws {
        let response = try SongSelectorTests.decodeResponse(songIDs: [])
        let result = selectBestMatch(response)
        #expect(result == nil, "selectBestMatch should return nil when no songs are present")
    }
}
