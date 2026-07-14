import Testing

@testable import IcecastMetadataCollector

@Suite("DominantColor Tests")
struct DominantColorTests {

    @Test("normalizedHex uppercases and prepends # to a bare 6-digit color")
    func normalizedHex_withBareLowercase_returnsPrefixedUppercase() {
        #expect(DominantColor().normalizedHex(fromAppleBgColor: "3d2a1c") == "#3D2A1C")
    }

    @Test("normalizedHex keeps an already-prefixed uppercase color")
    func normalizedHex_withPrefixedUppercase_returnsUnchanged() {
        #expect(DominantColor().normalizedHex(fromAppleBgColor: "#ABCDEF") == "#ABCDEF")
    }

    @Test("normalizedHex trims surrounding whitespace")
    func normalizedHex_withWhitespace_isTrimmed() {
        #expect(DominantColor().normalizedHex(fromAppleBgColor: "  1a2b3c\n") == "#1A2B3C")
    }

    @Test("normalizedHex output matches the client contract format")
    func normalizedHex_outputMatchesContractRegex() throws {
        let result = try #require(DominantColor().normalizedHex(fromAppleBgColor: "0f0f0f"))
        #expect(result.wholeMatch(of: /#[0-9A-F]{6}/) != nil)
    }

    @Test("normalizedHex returns nil for malformed input",
          arguments: ["", "12345", "1234567", "gggggg", "  ", "#12345", "12 34 56"])
    func normalizedHex_withMalformedInput_returnsNil(raw: String) {
        #expect(DominantColor().normalizedHex(fromAppleBgColor: raw) == nil)
    }
}
