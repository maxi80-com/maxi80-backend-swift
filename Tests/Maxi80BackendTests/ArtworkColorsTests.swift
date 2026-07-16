import Testing

@testable import IcecastMetadataCollector
@testable import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite("ArtworkColors Tests")
struct ArtworkColorsTests {

    /// Decodes a `Song.Attributes.Artwork` from JSON (the model has no public memberwise init;
    /// the codebase builds these types by decoding, matching SongSelectorTests).
    private func artwork(
        bg: String,
        t1: String,
        t2: String,
        t3: String,
        t4: String
    ) throws
        -> Song.Attributes.Artwork
    {
        let json = """
            {"width":1000,"height":1000,"url":"https://example/{w}x{h}.jpg",
             "bgColor":"\(bg)","textColor1":"\(t1)","textColor2":"\(t2)",
             "textColor3":"\(t3)","textColor4":"\(t4)"}
            """
        return try JSONDecoder().decode(Song.Attributes.Artwork.self, from: Data(json.utf8))
    }

    @Test("Builds normalized (# + uppercase) colors from Apple artwork")
    func buildsNormalizedColors() throws {
        let colors = try #require(
            ArtworkColors(artwork: try artwork(bg: "1c2520", t1: "e6b996", t2: "ddb5b1", t3: "be9c7e", t4: "b69894"))
        )
        #expect(colors.bg == "#1C2520")
        #expect(colors.text1 == "#E6B996")
        #expect(colors.text2 == "#DDB5B1")
        #expect(colors.text3 == "#BE9C7E")
        #expect(colors.text4 == "#B69894")
    }

    @Test("Returns nil when any Apple color is malformed")
    func nilOnMalformed() throws {
        let art = try artwork(bg: "zzz", t1: "e6b996", t2: "ddb5b1", t3: "be9c7e", t4: "b69894")
        #expect(ArtworkColors(artwork: art) == nil)
    }

    @Test("Round-trips through JSON with the client-contract keys")
    func jsonRoundTrip() throws {
        let colors = try #require(
            ArtworkColors(artwork: try artwork(bg: "000000", t1: "ffffff", t2: "cccccc", t3: "999999", t4: "666666"))
        )
        let data = try JSONEncoder().encode(colors)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"bg\":\"#000000\""))
        #expect(json.contains("\"text1\":\"#FFFFFF\""))
        let decoded = try JSONDecoder().decode(ArtworkColors.self, from: data)
        #expect(decoded == colors)
    }
}
