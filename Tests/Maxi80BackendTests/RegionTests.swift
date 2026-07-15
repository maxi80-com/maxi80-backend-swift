import Foundation
import SotoCore
import Testing

@testable import Maxi80Backend

@Suite("Region Tests")
struct RegionTests {

    @Test("Region creation from valid AWS region names")
    func testRegionFromValidNames() {
        // When
        let euCentral1 = Region(awsRegionName: "eu-central-1")
        let usEast1 = Region(awsRegionName: "us-east-1")
        let apSoutheast1 = Region(awsRegionName: "ap-southeast-1")

        // Then
        #expect(euCentral1 == .eucentral1)
        #expect(usEast1 == .useast1)
        #expect(apSoutheast1 == .apsoutheast1)
    }

    @Test("Region creation from invalid AWS region names")
    func testRegionFromInvalidNames() {
        // When
        let invalidRegion1 = Region(awsRegionName: "invalid-region")
        let emptyRegion = Region(awsRegionName: "")
        let numbersOnly = Region(awsRegionName: "12-east-1")
        let upperCase = Region(awsRegionName: "US-EAST-1")

        // Then
        #expect(invalidRegion1 == nil)
        #expect(emptyRegion == nil)
        #expect(numbersOnly == nil)
        #expect(upperCase == nil)

        // SotoCore's Region(awsRegionName:) validates against a known-region allowlist, so a
        // well-formed but non-existent region is rejected (stricter than the old custom regex —
        // this catches typos). All AWS regions the app actually uses are in the allowlist.
        let unknownRegion = Region(awsRegionName: "us-invalid-1")
        #expect(unknownRegion == nil)
    }

    @Test("Region raw values")
    func testRegionRawValues() {
        // Then
        #expect(Region.eucentral1.rawValue == "eu-central-1")
        #expect(Region.useast1.rawValue == "us-east-1")
        #expect(Region.uswest2.rawValue == "us-west-2")
        #expect(Region.apsoutheast1.rawValue == "ap-southeast-1")
    }

    @Test("Region description")
    func testRegionDescription() {
        // When
        let region = Region.eucentral1

        // Then
        #expect(region.description == "eu-central-1")
    }

    @Test("Region equality")
    func testRegionEquality() {
        // Given
        let region1 = Region.eucentral1
        let region2 = Region(rawValue: "eu-central-1")
        let region3 = Region.useast1

        // Then
        #expect(region1 == region2)
        #expect(region1 != region3)
    }

    @Test("Region encoding and decoding")
    func testRegionCodable() throws {
        // Given
        let region = Region.eucentral1

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(region)

        let decoder = JSONDecoder()
        let decodedRegion = try decoder.decode(Region.self, from: data)

        // Then
        #expect(decodedRegion == region)
        #expect(decodedRegion.rawValue == "eu-central-1")
    }

    @Test("Region other function")
    func testRegionOther() {
        // When
        let customRegion = Region.other("custom-region-1")

        // Then
        #expect(customRegion.rawValue == "custom-region-1")
        #expect(customRegion.description == "custom-region-1")
    }
}
