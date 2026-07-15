import Testing

@testable import Maxi80Backend

@Suite("Metadata Parser Tests")
struct MetadataParserTests {

    @Test("Standard format with space-dash-space separator")
    func testStandardFormat() {
        let result = parseTrackMetadata("Rita Mitsouko - Andy")
        #expect(result.artist == "Rita Mitsouko")
        #expect(result.title == "Andy")
    }

    @Test("Format with dash separator only")
    func testDashSeparatorOnly() {
        let result = parseTrackMetadata("Freeez- I O U")
        #expect(result.artist == "Freeez")
        #expect(result.title == "I O U")
    }

    @Test("Multiple separators - uses last one")
    func testMultipleSeparators() {
        let result = parseTrackMetadata("Jean-Jacques Goldman - Au bout de mes rêves (actu 1983)")
        #expect(result.artist == "Jean-Jacques Goldman")
        // The full title is preserved; parentheses are stripped only for the search term.
        #expect(result.title == "Au bout de mes rêves (actu 1983)")
    }

    @Test("Maxi 80 artist normalization")
    func testMaxi80Normalization() {
        let result1 = parseTrackMetadata("Maxi 80 - Eighties Best Music")
        #expect(result1.artist == "Maxi80")
        #expect(result1.title == "Eighties Best Music")

        let result2 = parseTrackMetadata("Maxi80 - Le Meilleur Son 80s")
        #expect(result2.artist == "Maxi80")
        #expect(result2.title == "Le Meilleur Son 80s")
    }

    @Test("No separator - defaults to Maxi80 artist")
    func testNoSeparator() {
        let result1 = parseTrackMetadata("IN THE MIX avec DJ LUCKY")
        #expect(result1.artist == "Maxi80")
        #expect(result1.title == "IN THE MIX avec DJ LUCKY")

        let result2 = parseTrackMetadata("Jouez au Grand Quiz des Années 80 !")
        #expect(result2.artist == "Maxi80")
        #expect(result2.title == "Jouez au Grand Quiz des Années 80 !")

        let result3 = parseTrackMetadata("Devenez Sponsor de Maxi 80")
        #expect(result3.artist == "Maxi80")
        #expect(result3.title == "Devenez Sponsor de Maxi 80")
    }

    @Test("Edge cases")
    func testEdgeCases() {
        // Empty string
        let empty = parseTrackMetadata("")
        #expect(empty.artist == nil)
        #expect(empty.title == nil)

        // Whitespace only
        let whitespace = parseTrackMetadata("   ")
        #expect(whitespace.artist == nil)
        #expect(whitespace.title == nil)

        // Only separator
        let onlySeparator = parseTrackMetadata(" - ")
        #expect(onlySeparator.artist == nil)
        #expect(onlySeparator.title == nil)
    }

    @Test("Complex artist names with hyphens")
    func testComplexArtistNames() {
        let result1 = parseTrackMetadata("Lloyd Cole And The Commotions - Lost Weekend")
        #expect(result1.artist == "Lloyd Cole And The Commotions")
        #expect(result1.title == "Lost Weekend")

        let result2 = parseTrackMetadata("Philip Oakey & Giorgio Moroder - Good Bye Bad Times")
        #expect(result2.artist == "Philip Oakey & Giorgio Moroder")
        #expect(result2.title == "Good Bye Bad Times")

        let result3 = parseTrackMetadata("Michael Jackson - Diana Ross - Ease On Down The Road")
        #expect(result3.artist == "Michael Jackson - Diana Ross")
        #expect(result3.title == "Ease On Down The Road")
    }

    @Test("Full title is preserved (parentheses NOT stripped by the parser)")
    func testTitlePreservesParentheses() {
        let result1 = parseTrackMetadata("Jean-Jacques Goldman - Au bout de mes rêves (actu 1983)")
        #expect(result1.artist == "Jean-Jacques Goldman")
        #expect(result1.title == "Au bout de mes rêves (actu 1983)")

        let result2 = parseTrackMetadata("Michael Jackson - PYT (Pretty Young Thing)")
        #expect(result2.artist == "Michael Jackson")
        #expect(result2.title == "PYT (Pretty Young Thing)")

        // No parentheses — unchanged.
        let result3 = parseTrackMetadata("Rita Mitsouko - Andy")
        #expect(result3.artist == "Rita Mitsouko")
        #expect(result3.title == "Andy")
    }

    @Test("searchTitle strips only trailing parentheses for the Apple Music query")
    func testSearchTitleStripping() {
        // Trailing parentheses are dropped for the search term.
        #expect(searchTitle("PYT (Pretty Young Thing)") == "PYT")
        #expect(searchTitle("Au bout de mes rêves (actu 1983)") == "Au bout de mes rêves")
        #expect(searchTitle("Passion (maxi 45 T)") == "Passion")

        // No trailing parentheses — returned unchanged.
        #expect(searchTitle("Andy") == "Andy")

        // Parentheses in the middle are NOT stripped.
        #expect(searchTitle("Title (middle) end") == "Title (middle) end")
    }

    @Test("Sample data validation")
    func testSampleData() {
        // Test a selection of actual metadata entries
        let samples = [
            ("Rita Mitsouko - Andy", "Rita Mitsouko", "Andy"),
            ("Freeez- I O U", "Freeez", "I O U"),
            ("Maxi 80 - Eighties Best Music", "Maxi80", "Eighties Best Music"),
            ("IN THE MIX avec DJ LUCKY", "Maxi80", "IN THE MIX avec DJ LUCKY"),
            (
                "Michael Jackson - Diana Ross - Ease On Down The Road", "Michael Jackson - Diana Ross",
                "Ease On Down The Road"
            ),
            ("muriel dacq-là ou ça", "Maxi80", "muriel dacq-là ou ça"),
            (
                "Jean-Jacques Goldman - Au bout de mes rêves (actu 1983)", "Jean-Jacques Goldman",
                "Au bout de mes rêves (actu 1983)"
            ),
            ("Ub40 - I got you babe (actu 1985)", "Ub40", "I got you babe (actu 1985)"),
        ]

        for (input, expectedArtist, expectedTitle) in samples {
            let result = parseTrackMetadata(input)
            #expect(result.artist == expectedArtist, "Failed for input: \(input)")
            #expect(result.title == expectedTitle, "Failed for input: \(input)")
        }
    }
}
