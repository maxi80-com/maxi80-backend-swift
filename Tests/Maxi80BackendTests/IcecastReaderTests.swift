import AsyncHTTPClient
import NIOHTTP1
import Testing

@testable import IcecastMetadataCollector

@Suite("IcecastReader Tests")
struct IcecastReaderTests {

    let reader = IcecastReader()

    // MARK: - Random URL Generator

    /// Generates an array of random URL strings with varied schemes, hosts, ports, paths, and query strings.
    static func generateRandomURLs(count: Int) -> [String] {
        var rng = SystemRandomNumberGenerator()
        var urls: [String] = []

        let schemes = ["http", "https", "icy"]
        let tlds = ["com", "net", "org", "io", "fm", "radio", "stream"]
        let alphanumeric = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let pathSegmentChars = Array("abcdefghijklmnopqrstuvwxyz0123456789-_")

        func randomString(length: Int) -> String {
            String((0..<length).map { _ in alphanumeric[Int.random(in: 0..<alphanumeric.count, using: &rng)] })
        }

        func randomPathSegment() -> String {
            String(
                (0..<Int.random(in: 1...12, using: &rng)).map { _ in
                    pathSegmentChars[Int.random(in: 0..<pathSegmentChars.count, using: &rng)]
                }
            )
        }

        for _ in 0..<count {
            let scheme = schemes[Int.random(in: 0..<schemes.count, using: &rng)]
            let hostLength = Int.random(in: 3...15, using: &rng)
            let host = randomString(length: hostLength)
            let tld = tlds[Int.random(in: 0..<tlds.count, using: &rng)]

            var url = "\(scheme)://\(host).\(tld)"

            // Optionally add a port
            if Bool.random(using: &rng) {
                let port = Int.random(in: 80...65535, using: &rng)
                url += ":\(port)"
            }

            // Optionally add path segments
            let pathDepth = Int.random(in: 0...4, using: &rng)
            for _ in 0..<pathDepth {
                url += "/\(randomPathSegment())"
            }

            // Optionally add a query string
            if Bool.random(using: &rng) {
                let paramCount = Int.random(in: 1...3, using: &rng)
                var params: [String] = []
                for _ in 0..<paramCount {
                    params.append("\(randomString(length: 4))=\(randomString(length: 6))")
                }
                url += "?\(params.joined(separator: "&"))"
            }

            urls.append(url)
        }

        return urls
    }

    // MARK: - Random Metadata String Generator

    /// Generates an array of random non-empty strings using alphanumeric characters and spaces.
    /// Avoids single quotes to prevent conflicts with the `StreamTitle='...'` format.
    static func generateRandomMetadataStrings(count: Int) -> [String] {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ")

        var strings: [String] = []
        for _ in 0..<count {
            let length = Int.random(in: 1...200, using: &rng)
            let value = String(
                (0..<length).map { _ in
                    chars[Int.random(in: 0..<chars.count, using: &rng)]
                }
            )
            strings.append(value)
        }
        return strings
    }

    // MARK: - Icecast Stream Test Case Generator

    struct IcecastStreamTestCase: CustomStringConvertible, Sendable {
        let metaInt: Int
        let metadataString: String
        var description: String { "metaInt=\(metaInt), metadata='\(metadataString)'" }
    }

    /// Generates random test cases with a random icy-metaint value and a random alphanumeric metadata string.
    static func generateStreamTestCases(count: Int) -> [IcecastStreamTestCase] {
        var rng = SystemRandomNumberGenerator()
        let alphanumeric = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -")

        var cases: [IcecastStreamTestCase] = []
        for _ in 0..<count {
            let metaInt = Int.random(in: 1...16384, using: &rng)
            let length = Int.random(in: 1...200, using: &rng)
            let metadata = String(
                (0..<length).map { _ in
                    alphanumeric[Int.random(in: 0..<alphanumeric.count, using: &rng)]
                }
            )
            cases.append(IcecastStreamTestCase(metaInt: metaInt, metadataString: metadata))
        }
        return cases
    }

    // MARK: - Property Tests

    // Feature: icecast-metadata-collector, Property 1: Icy-MetaData request header
    /// **Validates: Requirements 1.1**
    @Test(
        "Property 1: Icy-MetaData request header is always present",
        arguments: generateRandomURLs(count: 100)
    )
    func icyMetaDataHeaderAlwaysPresent(url: String) {
        let request = reader.buildRequest(for: url)
        let headerValue = request.headers.first(name: "Icy-MetaData")
        #expect(headerValue == "1", "Request for URL '\(url)' must include Icy-MetaData: 1 header")
    }

    // Feature: icecast-metadata-collector, Property 2: Icecast protocol byte stream parsing (round trip)
    /// **Validates: Requirements 1.2, 1.3**
    @Test(
        "Property 2: Icecast byte stream round trip",
        arguments: generateStreamTestCases(count: 100)
    )
    func icecastByteStreamRoundTrip(testCase: IcecastStreamTestCase) {
        // Build the StreamTitle metadata payload
        let streamTitle = "StreamTitle='\(testCase.metadataString)';"
        let metadataBytes = Array(streamTitle.utf8)
        let lengthByte = UInt8((metadataBytes.count + 15) / 16)
        let paddedLength = Int(lengthByte) * 16
        var metadataBlock = metadataBytes
        metadataBlock.append(contentsOf: [UInt8](repeating: 0, count: paddedLength - metadataBytes.count))

        // Build buffer: random audio bytes + length byte + padded metadata block
        var buffer = (0..<testCase.metaInt).map { _ in UInt8.random(in: 0...255) }
        buffer.append(lengthByte)
        buffer.append(contentsOf: metadataBlock)

        let result = reader.parseMetadataFromStream(buffer: buffer, metaInt: testCase.metaInt)
        #expect(result == testCase.metadataString)
    }

    // Feature: icecast-metadata-collector, Property 3: StreamTitle extraction
    /// **Validates: Requirements 1.4**
    @Test(
        "Property 3: StreamTitle extraction",
        arguments: generateRandomMetadataStrings(count: 100)
    )
    func streamTitleExtraction(value: String) {
        let wrapped = "StreamTitle='\(value)';"
        let result = reader.extractStreamTitle(wrapped)
        #expect(result == value)
    }
}

// MARK: - Unit Tests

extension IcecastReaderTests {

    /// Test extractStreamTitle returns nil for empty StreamTitle
    /// _Requirements: 1.6, 1.7_
    @Test("extractStreamTitle returns nil for empty StreamTitle")
    func extractStreamTitleReturnsNilForEmpty() {
        let result = reader.extractStreamTitle("StreamTitle='';")
        #expect(result == nil)
    }

    /// Test extractStreamTitle returns nil for missing format
    /// _Requirements: 1.6, 1.7_
    @Test("extractStreamTitle returns nil for missing StreamTitle format")
    func extractStreamTitleReturnsNilForMissingFormat() {
        let result = reader.extractStreamTitle("SomeOtherField=value;")
        #expect(result == nil)
    }

    /// Test parseMetadataFromStream returns nil when buffer too short
    /// _Requirements: 1.6, 1.7_
    @Test("parseMetadataFromStream returns nil when buffer is shorter than metaInt")
    func parseMetadataReturnsNilWhenBufferTooShort() {
        let metaInt = 100
        // Buffer has fewer bytes than metaInt, so we can never reach a length byte
        let buffer = [UInt8](repeating: 0, count: 50)
        let result = reader.parseMetadataFromStream(buffer: buffer, metaInt: metaInt)
        #expect(result == nil)
    }

    /// Test parseMetadataFromStream skips empty metadata blocks
    /// _Requirements: 8.3_
    @Test("parseMetadataFromStream skips empty metadata block and returns next valid title")
    func parseMetadataSkipsEmptyBlock() {
        let metaInt = 8

        // --- First metadata block: empty (length byte = 0) ---
        var buffer = [UInt8](repeating: 0xAA, count: metaInt)  // 8 audio bytes
        buffer.append(0)  // length byte = 0 → empty metadata block

        // --- Second metadata block: valid StreamTitle ---
        buffer.append(contentsOf: [UInt8](repeating: 0xBB, count: metaInt))  // 8 more audio bytes
        let title = "StreamTitle='Hello World';"
        let titleBytes = Array(title.utf8)
        let lengthByte = UInt8((titleBytes.count + 15) / 16)
        let paddedLength = Int(lengthByte) * 16
        buffer.append(lengthByte)
        buffer.append(contentsOf: titleBytes)
        buffer.append(contentsOf: [UInt8](repeating: 0, count: paddedLength - titleBytes.count))

        let result = reader.parseMetadataFromStream(buffer: buffer, metaInt: metaInt)
        #expect(result == "Hello World")
    }

    /// Test parseMetadataFromStream returns first non-empty StreamTitle (stops reading)
    /// _Requirements: 8.3_
    @Test("parseMetadataFromStream returns first non-empty StreamTitle and stops")
    func parseMetadataReturnsFirstTitle() {
        let metaInt = 4

        // --- First metadata block with a valid StreamTitle ---
        var buffer = [UInt8](repeating: 0xAA, count: metaInt)  // 4 audio bytes
        let firstTitle = "StreamTitle='First Song';"
        let firstBytes = Array(firstTitle.utf8)
        let firstLengthByte = UInt8((firstBytes.count + 15) / 16)
        let firstPadded = Int(firstLengthByte) * 16
        buffer.append(firstLengthByte)
        buffer.append(contentsOf: firstBytes)
        buffer.append(contentsOf: [UInt8](repeating: 0, count: firstPadded - firstBytes.count))

        // --- Second metadata block with a different StreamTitle ---
        buffer.append(contentsOf: [UInt8](repeating: 0xBB, count: metaInt))  // 4 audio bytes
        let secondTitle = "StreamTitle='Second Song';"
        let secondBytes = Array(secondTitle.utf8)
        let secondLengthByte = UInt8((secondBytes.count + 15) / 16)
        let secondPadded = Int(secondLengthByte) * 16
        buffer.append(secondLengthByte)
        buffer.append(contentsOf: secondBytes)
        buffer.append(contentsOf: [UInt8](repeating: 0, count: secondPadded - secondBytes.count))

        let result = reader.parseMetadataFromStream(buffer: buffer, metaInt: metaInt)
        #expect(result == "First Song")
    }
}
