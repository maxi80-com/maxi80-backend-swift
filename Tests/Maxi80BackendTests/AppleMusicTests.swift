import Foundation
import Testing

@testable import Maxi80Backend

@Suite("Apple Music Tests")
struct AppleMusicTests {

    @Test("AppleMusicEndpoint URL generation")
    func testAppleMusicEndpointURL() {
        // Given
        let searchEndpoint = AppleMusicEndpoint.search

        // When
        let searchURL = searchEndpoint.url()

        let searchURLWithArgs = searchEndpoint.url(args: [
            URLQueryItem(name: "term", value: "Beatles"),
            URLQueryItem(name: "types", value: "artists,albums"),
        ])

        // Then
        #expect(searchURL.absoluteString == "https://api.music.apple.com/v1/catalog/fr/search")
        #expect(searchURLWithArgs.absoluteString.contains("term=Beatles"))
        #expect(searchURLWithArgs.absoluteString.contains("types=artists,albums"))

        #if DEBUG
        let testEndpoint = AppleMusicEndpoint.test
        let testURL = testEndpoint.url()
        #expect(testURL.absoluteString == "https://api.music.apple.com/v1/test")
        #endif
    }

    @Test("AppleMusicEndpoint from path")
    func testAppleMusicEndpointFromPath() {
        // When
        let searchEndpoint = AppleMusicEndpoint.from(path: "/catalog/fr/search")
        let invalidEndpoint = AppleMusicEndpoint.from(path: "/invalid")

        // Then
        #expect(searchEndpoint == .search)
        #expect(invalidEndpoint == nil)

        #if DEBUG
        let testEndpoint = AppleMusicEndpoint.from(path: "/test")
        #expect(testEndpoint == .test)
        #endif
    }

    @Test("AppleMusicSearchType items generation")
    func testAppleMusicSearchTypeItems() {
        // Given
        let searchTypes: [AppleMusicSearchType] = [.artists, .albums, .songs]

        // When
        let queryItem = AppleMusicSearchType.items(searchTypes: searchTypes)

        // Then
        #expect(queryItem.name == "types")
        #expect(queryItem.value == "artists,albums,songs")
    }

    @Test("AppleMusicSearchType term generation")
    func testAppleMusicSearchTypeTerm() {
        // Given
        let searchTerm = "Pink Floyd"

        // When
        let queryItem = AppleMusicSearchType.term(search: searchTerm)

        // Then
        #expect(queryItem.name == "term")
        #expect(queryItem.value == "Pink Floyd")
    }

    @Test("AppleMusicSecret encoding and decoding")
    func testAppleMusicSecretCodable() throws {
        // Given
        let secret = AppleMusicSecret(
            privateKey: "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----",
            teamId: "TEAM123456",
            keyId: "KEY123456"
        )

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(secret)

        let decoder = JSONDecoder()
        let decodedSecret = try decoder.decode(AppleMusicSecret.self, from: data)

        // Then
        #expect(decodedSecret.privateKey == secret.privateKey)
        #expect(decodedSecret.teamId == secret.teamId)
        #expect(decodedSecret.keyId == secret.keyId)
    }

    @Test("AppleMusicSecret decodes from key-file JSON")
    func testAppleMusicSecretKeyFileDecoding() throws {
        // Given
        let keyFileJSON = """
            {
                "keyId": "FAKEKEYID1",
                "privateKey": "-----BEGIN PRIVATE KEY-----\\nFAKEKEYCONTENT\\n-----END PRIVATE KEY-----",
                "teamId": "FAKETEAM01"
            }
            """

        // When
        let data = Data(keyFileJSON.utf8)
        let secret = try JSONDecoder().decode(AppleMusicSecret.self, from: data)

        // Then
        #expect(secret.keyId == "FAKEKEYID1")
        #expect(secret.teamId == "FAKETEAM01")
        #expect(secret.privateKey == "-----BEGIN PRIVATE KEY-----\nFAKEKEYCONTENT\n-----END PRIVATE KEY-----")
    }

    @Test("AppleMusicSecret description hides private key")
    func testAppleMusicSecretDescription() {
        // Given
        let secret = AppleMusicSecret(
            privateKey: "-----BEGIN PRIVATE KEY-----\nsecret-content\n-----END PRIVATE KEY-----",
            teamId: "TEAM123456",
            keyId: "KEY123456"
        )

        // When
        let description = secret.description

        // Then
        #expect(description.contains("TEAM123456"))
        #expect(description.contains("KEY123456"))
        #expect(!description.contains("secret-content"))
        #expect(description.contains("shuuuut"))
    }

    @Test("Apple Music model decoding - Song")
    func testSongDecoding() throws {
        // Given
        let songJSON = """
            {
                "id": "1234567890",
                "type": "songs",
                "href": "/v1/catalog/fr/songs/1234567890",
                "attributes": {
                    "albumName": "The Wall",
                    "artistName": "Pink Floyd",
                    "genreNames": ["Rock"],
                    "trackNumber": 1,
                    "durationInMillis": 231000,
                    "releaseDate": "1979-11-30",
                    "isrc": "GBUM71505078",
                    "artwork": {
                        "width": 1400,
                        "height": 1400,
                        "url": "https://example.com/artwork.jpg",
                        "bgColor": "000000",
                        "textColor1": "ffffff",
                        "textColor2": "cccccc",
                        "textColor3": "999999",
                        "textColor4": "666666"
                    },
                    "url": "https://music.apple.com/fr/album/another-brick-in-the-wall-pt-2/1065975633?i=1065975848",
                    "playParams": {
                        "id": "1234567890",
                        "kind": "song"
                    },
                    "discNumber": 1,
                    "name": "Another Brick in the Wall, Pt. 2",
                    "previews": [
                        {
                            "url": "https://example.com/preview.m4a"
                        }
                    ]
                }
            }
            """

        // When
        let data = songJSON.data(using: .utf8)!
        let decoder = JSONDecoder()
        let song = try decoder.decode(Song.self, from: data)

        // Then
        #expect(song.id == "1234567890")
        #expect(song.type == "songs")
        #expect(song.attributes.albumName == "The Wall")
        #expect(song.attributes.artistName == "Pink Floyd")
        #expect(song.attributes.name == "Another Brick in the Wall, Pt. 2")
        #expect(song.attributes.trackNumber == 1)
        #expect(song.attributes.durationInMillis == 231000)
        #expect(song.attributes.artwork?.width == 1400)
        #expect(song.attributes.artwork?.height == 1400)
        #expect(song.attributes.playParams.id == "1234567890")
        #expect(song.attributes.playParams.kind == "song")
        #expect(song.attributes.previews.count == 1)
        #expect(song.attributes.previews[0].url == "https://example.com/preview.m4a")
    }

    @Test("Apple Music model decoding - Search Response")
    func testSearchResponseDecoding() throws {
        // Given
        let searchResponseJSON = """
            {
                "meta": {
                    "results": {
                        "order": ["artists", "albums"],
                        "rawOrder": ["artists", "albums"]
                    }
                },
                "results": {
                    "artists": {
                        "data": [],
                        "href": "/v1/catalog/fr/search?term=test&types=artists"
                    },
                    "albums": {
                        "data": [],
                        "href": "/v1/catalog/fr/search?term=test&types=albums"
                    }
                }
            }
            """

        // When
        let data = searchResponseJSON.data(using: .utf8)!
        let decoder = JSONDecoder()
        let searchResponse = try decoder.decode(AppleMusicSearchResponse.self, from: data)

        // Then
        #expect(searchResponse.meta.results.order == ["artists", "albums"])
        #expect(searchResponse.meta.results.rawOrder == ["artists", "albums"])
        #expect(searchResponse.results.artists?.href == "/v1/catalog/fr/search?term=test&types=artists")
        #expect(searchResponse.results.albums?.href == "/v1/catalog/fr/search?term=test&types=albums")
        #expect(searchResponse.results.songs == nil)
    }
}
