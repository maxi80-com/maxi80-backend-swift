import Foundation
import Testing

@testable import Maxi80Backend

@Suite("Feature Flags Tests")
struct FeatureFlagsTests {

    // MARK: - FEATURE_FLAGS parsing

    @Test("Unset FEATURE_FLAGS yields no flags")
    func testParsingNilEnvironmentValue() {
        let flags = FeatureFlags(environmentValue: nil)

        #expect(flags.isEmpty)
        #expect(flags.values.isEmpty)
        #expect(flags.malformedEntries.isEmpty)
    }

    @Test("Blank FEATURE_FLAGS yields no flags", arguments: ["", "   ", "\n", ","])
    func testParsingBlankEnvironmentValue(value: String) {
        let flags = FeatureFlags(environmentValue: value)

        #expect(flags.isEmpty)
        #expect(flags.malformedEntries.isEmpty)
    }

    @Test("A single name=bool pair parses")
    func testParsingSingleFlag() {
        let flags = FeatureFlags(environmentValue: "anniversary_cover=true")

        #expect(flags.values == ["anniversary_cover": true])
        #expect(!flags.isEmpty)
        #expect(flags.malformedEntries.isEmpty)
    }

    @Test("Multiple comma-separated pairs parse, whitespace tolerated")
    func testParsingMultipleFlags() {
        let flags = FeatureFlags(environmentValue: " anniversary_cover = true , sleep_timer=false ")

        #expect(flags.values == ["anniversary_cover": true, "sleep_timer": false])
        #expect(flags.malformedEntries.isEmpty)
    }

    @Test(
        "Boolean values accept true/false and 1/0 case-insensitively",
        arguments: [
            ("flag=true", true),
            ("flag=TRUE", true),
            ("flag=True", true),
            ("flag=1", true),
            ("flag=false", false),
            ("flag=FALSE", false),
            ("flag=0", false),
        ]
    )
    func testParsingBooleanSpellings(entry: String, expected: Bool) {
        let flags = FeatureFlags(environmentValue: entry)

        #expect(flags.values == ["flag": expected])
        #expect(flags.malformedEntries.isEmpty)
    }

    @Test(
        "Malformed entries are skipped and reported, never thrown",
        arguments: ["no_equals_sign", "flag=maybe", "flag=", "=true", "  =  ", "flag=2"]
    )
    func testParsingMalformedEntry(entry: String) {
        let flags = FeatureFlags(environmentValue: entry)

        #expect(flags.isEmpty)
        #expect(flags.malformedEntries == [entry.trimmingWhitespace()])
    }

    @Test("A malformed entry does not discard the valid ones")
    func testParsingMixedValidAndMalformed() {
        let flags = FeatureFlags(environmentValue: "anniversary_cover=true,oops,sleep_timer=0")

        #expect(flags.values == ["anniversary_cover": true, "sleep_timer": false])
        #expect(flags.malformedEntries == ["oops"])
    }

    @Test("Trailing and repeated separators are ignored")
    func testParsingExtraSeparators() {
        let flags = FeatureFlags(environmentValue: "anniversary_cover=true,,sleep_timer=true,")

        #expect(flags.values == ["anniversary_cover": true, "sleep_timer": true])
        #expect(flags.malformedEntries.isEmpty)
    }

    @Test("A duplicated flag name keeps the last value")
    func testParsingDuplicateFlagName() {
        let flags = FeatureFlags(environmentValue: "anniversary_cover=false,anniversary_cover=true")

        #expect(flags.values == ["anniversary_cover": true])
    }

    @Test("A value containing '=' is kept whole rather than re-split")
    func testParsingOnlySplitsOnFirstEquals() {
        let flags = FeatureFlags(environmentValue: "flag=true=extra")

        #expect(flags.isEmpty)
        #expect(flags.malformedEntries == ["flag=true=extra"])
    }

    @Test("FeatureFlags.none carries no flags")
    func testNoneIsEmpty() {
        #expect(FeatureFlags.none.isEmpty)
        #expect(FeatureFlags.none.values.isEmpty)
    }

    @Test("The environment key is the documented FEATURE_FLAGS")
    func testEnvironmentKey() {
        #expect(FeatureFlags.environmentKey == "FEATURE_FLAGS")
    }

    // MARK: - Station serialization

    @Test("Configured flags serialize as a features object of booleans")
    func testStationEncodesFeatures() throws {
        let station = Station.default.withFeatures(
            FeatureFlags(environmentValue: "anniversary_cover=true,sleep_timer=false")
        )

        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(station)) as? [String: Any]
        )
        let features = try #require(json["features"] as? [String: Bool])

        #expect(features == ["anniversary_cover": true, "sleep_timer": false])
        // Existing fields are untouched.
        #expect(json["name"] as? String == "Maxi 80")
        #expect(json["streamUrl"] as? String == "https://audio1.maxi80.com")
    }

    @Test("With no flags configured the encoded JSON has no features key")
    func testStationOmitsFeaturesKeyWhenNoFlags() throws {
        let station = Station.default.withFeatures(.none)

        #expect(station.features == nil)

        let data = try JSONEncoder().encode(station)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Neither `"features": {}` nor `"features": null` — the key must be absent so pre-flags
        // app versions see exactly the payload they were built against.
        #expect(json["features"] == nil)
        #expect(json.keys.contains("features") == false)
        #expect(!String(decoding: data, as: UTF8.self).contains("features"))
    }

    @Test("Station.default alone carries no features key")
    func testStationDefaultHasNoFeatures() throws {
        #expect(Station.default.features == nil)

        let data = try JSONEncoder().encode(Station.default)
        #expect(!String(decoding: data, as: UTF8.self).contains("features"))
    }

    @Test("An empty features dictionary collapses to the absent form")
    func testStationCollapsesEmptyFeaturesDictionary() throws {
        let station = Station(
            name: "Test",
            streamUrl: "https://example.com",
            image: "i.png",
            shortDesc: "s",
            longDesc: "l",
            websiteUrl: "https://example.com",
            donationUrl: "https://example.com",
            defaultCoverUrl: "file://i.png",
            features: [:]
        )

        #expect(station.features == nil)
        #expect(!String(decoding: try JSONEncoder().encode(station), as: UTF8.self).contains("features"))
    }

    @Test("A pre-feature-flags payload still decodes, with nil features")
    func testStationDecodesLegacyPayloadWithoutFeatures() throws {
        let legacy = """
            {
              "name": "Maxi 80",
              "streamUrl": "https://audio1.maxi80.com",
              "image": "maxi80_nocover-b.png",
              "shortDesc": "La radio de toute une génération",
              "longDesc": "Le meilleur de la musique des années 80",
              "websiteUrl": "https://maxi80.com",
              "donationUrl": "https://www.maxi80.com/paypal.htm",
              "defaultCoverUrl": "file://maxi80_nocover-b.png"
            }
            """

        let station = try JSONDecoder().decode(Station.self, from: Data(legacy.utf8))

        #expect(station.features == nil)
        #expect(station.name == "Maxi 80")
    }

    @Test("A features object round-trips through encode/decode")
    func testStationFeaturesRoundTrip() throws {
        let original = Station.default.withFeatures(FeatureFlags(environmentValue: "anniversary_cover=true"))

        let decoded = try JSONDecoder().decode(Station.self, from: JSONEncoder().encode(original))

        #expect(decoded.features == ["anniversary_cover": true])
    }

    @Test("An explicit null features value decodes to nil")
    func testStationDecodesNullFeatures() throws {
        let json = """
            {
              "name": "Maxi 80",
              "streamUrl": "https://audio1.maxi80.com",
              "image": "i.png",
              "shortDesc": "s",
              "longDesc": "l",
              "websiteUrl": "https://maxi80.com",
              "donationUrl": "https://maxi80.com",
              "defaultCoverUrl": "file://i.png",
              "features": null
            }
            """

        let station = try JSONDecoder().decode(Station.self, from: Data(json.utf8))

        #expect(station.features == nil)
    }
}
