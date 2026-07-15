import Testing

@testable import IcecastMetadataCollector

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@Suite("HistoryManager Tests")
struct HistoryManagerTests {

    // MARK: - Property 1: Serialization round-trip

    struct SerializationTestCase: CustomStringConvertible, Sendable {
        let historyFile: HistoryFile
        var description: String { "entries=\(historyFile.entries.count)" }
    }

    static func generateSerializationTestCases(count: Int) -> [SerializationTestCase] {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ /.:+")

        func randomString(minLen: Int = 1, maxLen: Int = 30) -> String {
            let length = Int.random(in: minLen...maxLen, using: &rng)
            return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
        }

        func randomHexColor() -> String? {
            guard Bool.random(using: &rng) else { return nil }
            let digits = "0123456789ABCDEF"
            return "#" + String((0..<6).map { _ in digits.randomElement(using: &rng)! })
        }

        func randomEntry() -> HistoryEntry {
            HistoryEntry(
                artist: randomString(),
                title: randomString(),
                artwork: randomString(),
                timestamp: randomString(),
                color: randomHexColor()
            )
        }

        return (0..<count).map { _ in
            let entryCount = Int.random(in: 0...20, using: &rng)
            let entries = (0..<entryCount).map { _ in randomEntry() }
            return SerializationTestCase(historyFile: HistoryFile(entries: entries))
        }
    }

    // Feature: lookup-history, Property 1: Serialization round-trip
    /// **Validates: Requirements 7.1, 1.4**
    @Test(
        "Property 1: Serialization round-trip",
        arguments: generateSerializationTestCases(count: 100)
    )
    func serializationRoundTrip(testCase: SerializationTestCase) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let data = try encoder.encode(testCase.historyFile)
        let decoded = try JSONDecoder().decode(HistoryFile.self, from: data)

        #expect(decoded == testCase.historyFile)
    }
}

// MARK: - Property 2: Serialized JSON structure contains required keys

extension HistoryManagerTests {

    struct JSONStructureTestCase: CustomStringConvertible, Sendable {
        let entry: HistoryEntry
        var description: String { "artist='\(entry.artist)', title='\(entry.title)'" }
    }

    static func generateJSONStructureTestCases(count: Int) -> [JSONStructureTestCase] {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ /.:+")

        func randomString(minLen: Int = 1, maxLen: Int = 30) -> String {
            let length = Int.random(in: minLen...maxLen, using: &rng)
            return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
        }

        func randomHexColor() -> String? {
            guard Bool.random(using: &rng) else { return nil }
            let digits = "0123456789ABCDEF"
            return "#" + String((0..<6).map { _ in digits.randomElement(using: &rng)! })
        }

        return (0..<count).map { _ in
            let entry = HistoryEntry(
                artist: randomString(),
                title: randomString(),
                artwork: randomString(),
                timestamp: randomString(),
                color: randomHexColor()
            )
            return JSONStructureTestCase(entry: entry)
        }
    }

    // Feature: lookup-history, Property 2: Serialized JSON structure contains required keys
    /// **Validates: Requirements 1.1, 1.2**
    @Test(
        "Property 2: Serialized JSON structure contains required keys",
        arguments: generateJSONStructureTestCases(count: 100)
    )
    func jsonStructureContainsRequiredKeys(testCase: JSONStructureTestCase) throws {
        let data = try JSONEncoder().encode(testCase.entry)

        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(jsonObject as? [String: Any])

        var expectedKeys: Set<String> = ["artist", "title", "artwork", "timestamp"]
        if testCase.entry.color != nil { expectedKeys.insert("color") }
        #expect(Set(dict.keys) == expectedKeys, "Expected exactly keys \(expectedKeys), got \(Set(dict.keys))")

        #expect(dict["artist"] is String, "artist value should be a String")
        #expect(dict["title"] is String, "title value should be a String")
        #expect(dict["artwork"] is String, "artwork value should be a String")
        #expect(dict["timestamp"] is String, "timestamp value should be a String")
        if testCase.entry.color != nil {
            #expect(dict["color"] is String, "color value should be a String when present")
        }
    }
}

// MARK: - Color field encoding / decoding

extension HistoryManagerTests {

    @Test("Entry with a color encodes the hex string and round-trips")
    func entryWithColor_roundTrips() throws {
        let entry = HistoryEntry(
            artist: "Sandra",
            title: "Secret Land",
            artwork: "v2/Sandra/Secret Land/artwork.jpg",
            timestamp: "2026-07-13T10:54:27Z",
            color: "#3D2A1C"
        )

        let data = try JSONEncoder().encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"color\":\"#3D2A1C\""))

        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)
        #expect(decoded == entry)
        #expect(decoded.color == "#3D2A1C")
    }

    @Test("Entry without a color omits the key entirely — never null")
    func entryWithoutColor_omitsKey() throws {
        let entry = HistoryEntry(artist: "A", title: "B", artwork: "k", timestamp: "t")

        let data = try JSONEncoder().encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("color"))
        #expect(!json.contains("null"))
    }

    @Test("Legacy JSON without a color key decodes with color == nil")
    func legacyJSON_decodesWithNilColor() throws {
        let legacy = #"{"artist":"A","title":"B","artwork":"k","timestamp":"t"}"#
        let data = try #require(legacy.data(using: .utf8))

        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)
        #expect(decoded.color == nil)
        #expect(decoded == HistoryEntry(artist: "A", title: "B", artwork: "k", timestamp: "t"))
    }

    @Test("Mixed HistoryFile — colored and colorless entries all decode")
    func mixedHistoryFile_allDecode() throws {
        let entries = [
            HistoryEntry(artist: "A", title: "B", artwork: "a.jpg", timestamp: "t1", color: "#112233"),
            HistoryEntry(artist: "C", title: "D", artwork: "b.jpg", timestamp: "t2"),
        ]
        let file = HistoryFile(entries: entries)

        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(HistoryFile.self, from: data)

        #expect(decoded == file)
        #expect(decoded.entries[0].color == "#112233")
        #expect(decoded.entries[1].color == nil)
    }
}

// MARK: - Property 3: Size invariant after append-and-trim

extension HistoryManagerTests {

    struct SizeInvariantTestCase: CustomStringConvertible, Sendable {
        let historyFile: HistoryFile
        let newEntry: HistoryEntry
        let maxSize: Int
        var description: String { "entries=\(historyFile.entries.count), maxSize=\(maxSize)" }
    }

    static func generateSizeInvariantTestCases(count: Int) -> [SizeInvariantTestCase] {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ /.:+")

        func randomString(minLen: Int = 1, maxLen: Int = 30) -> String {
            let length = Int.random(in: minLen...maxLen, using: &rng)
            return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
        }

        func randomEntry() -> HistoryEntry {
            HistoryEntry(
                artist: randomString(),
                title: randomString(),
                artwork: randomString(),
                timestamp: randomString()
            )
        }

        return (0..<count).map { _ in
            let entryCount = Int.random(in: 0...20, using: &rng)
            let entries = (0..<entryCount).map { _ in randomEntry() }
            let historyFile = HistoryFile(entries: entries)
            let newEntry = randomEntry()
            let maxSize = Int.random(in: 1...25, using: &rng)
            return SizeInvariantTestCase(historyFile: historyFile, newEntry: newEntry, maxSize: maxSize)
        }
    }

    // Feature: lookup-history, Property 3: Size invariant after append-and-trim
    /// **Validates: Requirements 2.1, 4.3**
    @Test(
        "Property 3: Size invariant after append-and-trim",
        arguments: generateSizeInvariantTestCases(count: 100)
    )
    func sizeInvariantAfterAppendAndTrim(testCase: SizeInvariantTestCase) {
        let result = HistoryManager.appendAndTrim(
            entry: testCase.newEntry,
            to: testCase.historyFile,
            maxSize: testCase.maxSize
        )

        let expectedCount = min(testCase.historyFile.entries.count + 1, testCase.maxSize)
        #expect(
            result.entries.count == expectedCount,
            "Expected \(expectedCount) entries (min(\(testCase.historyFile.entries.count) + 1, \(testCase.maxSize))), got \(result.entries.count)"
        )
    }
}

// MARK: - Property 4: Ordering — new entry is last, oldest trimmed first

extension HistoryManagerTests {

    struct OrderingTestCase: CustomStringConvertible, Sendable {
        let historyFile: HistoryFile
        let newEntry: HistoryEntry
        let maxSize: Int
        var description: String { "entries=\(historyFile.entries.count), maxSize=\(maxSize)" }
    }

    static func generateOrderingTestCases(count: Int) -> [OrderingTestCase] {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ /.:+")

        func randomString(minLen: Int = 1, maxLen: Int = 30) -> String {
            let length = Int.random(in: minLen...maxLen, using: &rng)
            return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
        }

        func randomEntry() -> HistoryEntry {
            HistoryEntry(
                artist: randomString(),
                title: randomString(),
                artwork: randomString(),
                timestamp: randomString()
            )
        }

        return (0..<count).map { _ in
            let entryCount = Int.random(in: 0...20, using: &rng)
            let entries = (0..<entryCount).map { _ in randomEntry() }
            let historyFile = HistoryFile(entries: entries)
            let newEntry = randomEntry()
            let maxSize = Int.random(in: 1...25, using: &rng)
            return OrderingTestCase(historyFile: historyFile, newEntry: newEntry, maxSize: maxSize)
        }
    }

    // Feature: lookup-history, Property 4: Ordering — new entry is last, oldest trimmed first
    /// **Validates: Requirements 2.3, 4.4**
    @Test(
        "Property 4: Ordering — new entry is last, oldest trimmed first",
        arguments: generateOrderingTestCases(count: 100)
    )
    func orderingNewEntryIsLastOldestTrimmedFirst(testCase: OrderingTestCase) {
        let result = HistoryManager.appendAndTrim(
            entry: testCase.newEntry,
            to: testCase.historyFile,
            maxSize: testCase.maxSize
        )

        // The last element must be the newly appended entry
        #expect(
            result.entries.last == testCase.newEntry,
            "Last entry should be the newly appended entry"
        )

        // The preceding entries (all but last) must be a suffix of the original entries array
        let preceding = Array(result.entries.dropLast())
        let originalSuffix = Array(testCase.historyFile.entries.suffix(preceding.count))
        #expect(
            preceding == originalSuffix,
            "Preceding entries should be a suffix of the original entries array"
        )
    }
}

// MARK: - Property 5: Duplicate entries are preserved

extension HistoryManagerTests {

    struct DuplicateTestCase: CustomStringConvertible, Sendable {
        let historyFile: HistoryFile
        let newEntry: HistoryEntry
        let originalEntry: HistoryEntry
        let maxSize: Int
        var description: String {
            "entries=\(historyFile.entries.count), duplicate artist='\(newEntry.artist)', title='\(newEntry.title)'"
        }
    }

    static func generateDuplicateTestCases(count: Int) -> [DuplicateTestCase] {
        var rng = SystemRandomNumberGenerator()
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ /.:+")

        func randomString(minLen: Int = 1, maxLen: Int = 30) -> String {
            let length = Int.random(in: minLen...maxLen, using: &rng)
            return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &rng)] })
        }

        func randomEntry() -> HistoryEntry {
            HistoryEntry(
                artist: randomString(),
                title: randomString(),
                artwork: randomString(),
                timestamp: randomString()
            )
        }

        return (0..<count).map { _ in
            // Generate a history with at least 1 entry
            let entryCount = Int.random(in: 1...20, using: &rng)
            let entries = (0..<entryCount).map { _ in randomEntry() }
            let historyFile = HistoryFile(entries: entries)

            // Pick a random existing entry to duplicate artist/title from
            let pickedEntry = entries[Int.random(in: 0..<entries.count, using: &rng)]

            // Create a new entry with the same artist/title but different artwork/timestamp
            let newEntry = HistoryEntry(
                artist: pickedEntry.artist,
                title: pickedEntry.title,
                artwork: randomString(),
                timestamp: randomString()
            )

            // maxSize large enough to hold all entries plus the new one (no trimming)
            let maxSize = entries.count + 1

            return DuplicateTestCase(
                historyFile: historyFile,
                newEntry: newEntry,
                originalEntry: pickedEntry,
                maxSize: maxSize
            )
        }
    }

    // Feature: lookup-history, Property 5: Duplicate entries are preserved
    /// **Validates: Requirements 2.2**
    @Test(
        "Property 5: Duplicate entries are preserved",
        arguments: generateDuplicateTestCases(count: 100)
    )
    func duplicateEntriesArePreserved(testCase: DuplicateTestCase) {
        let result = HistoryManager.appendAndTrim(
            entry: testCase.newEntry,
            to: testCase.historyFile,
            maxSize: testCase.maxSize
        )

        // The original entry should still be present in the result
        #expect(
            result.entries.contains(testCase.originalEntry),
            "Original entry should still be present — no deduplication"
        )

        // The new entry (same artist/title, different artwork/timestamp) should also be present
        #expect(
            result.entries.contains(testCase.newEntry),
            "New duplicate entry should also be present in the result"
        )

        // Both entries should exist — verify at least 2 entries share the same artist/title
        let matchingEntries = result.entries.filter {
            $0.artist == testCase.newEntry.artist && $0.title == testCase.newEntry.title
        }
        #expect(
            matchingEntries.count >= 2,
            "At least 2 entries with the same artist/title should exist, got \(matchingEntries.count)"
        )
    }
}

// MARK: - Edge Case Unit Tests

extension HistoryManagerTests {

    /// **Validates: Requirements 3.3** — First run: empty history produces exactly one entry.
    @Test("appendAndTrim with empty HistoryFile produces exactly one entry")
    func appendToEmptyHistory() {
        let emptyHistory = HistoryFile(entries: [])
        let entry = HistoryEntry(
            artist: "Duran Duran",
            title: "Rio",
            artwork: "collected/Duran Duran/Rio/artwork.jpg",
            timestamp: "2025-07-15T14:30:00Z"
        )

        let result = HistoryManager.appendAndTrim(entry: entry, to: emptyHistory, maxSize: 10)

        #expect(result.entries.count == 1, "Should have exactly 1 entry after appending to empty history")
        #expect(result.entries.first == entry, "The single entry should be the one we appended")
    }

    /// **Validates: Requirements 4.3, 4.4** — At boundary: history at exactly maxSize, append one, count stays at maxSize, oldest trimmed.
    @Test("Trimming at boundary: history at exactly maxSize stays at maxSize after append")
    func trimmingAtBoundary() {
        let maxSize = 5
        let originalEntries = (0..<maxSize).map { i in
            HistoryEntry(
                artist: "Artist \(i)",
                title: "Title \(i)",
                artwork: "art/\(i).jpg",
                timestamp: "2025-07-15T14:0\(i):00Z"
            )
        }
        let history = HistoryFile(entries: originalEntries)
        let newEntry = HistoryEntry(
            artist: "New Artist",
            title: "New Title",
            artwork: "art/new.jpg",
            timestamp: "2025-07-15T15:00:00Z"
        )

        let result = HistoryManager.appendAndTrim(entry: newEntry, to: history, maxSize: maxSize)

        #expect(
            result.entries.count == maxSize,
            "Count should stay at maxSize (\(maxSize)), not \(result.entries.count)"
        )
        #expect(result.entries.last == newEntry, "Last entry should be the newly appended one")
        #expect(!result.entries.contains(originalEntries[0]), "First original entry should have been trimmed")
    }

    /// **Validates: Requirements 4.3** — maxSize = 1 always produces a single-entry result.
    @Test("appendAndTrim with maxSize = 1 always produces single-entry result")
    func maxSizeOneProducesSingleEntry() {
        let entries = (0..<3).map { i in
            HistoryEntry(
                artist: "Artist \(i)",
                title: "Title \(i)",
                artwork: "art/\(i).jpg",
                timestamp: "2025-07-15T14:0\(i):00Z"
            )
        }
        let history = HistoryFile(entries: entries)
        let newEntry = HistoryEntry(
            artist: "Solo Artist",
            title: "Solo Title",
            artwork: "art/solo.jpg",
            timestamp: "2025-07-15T15:00:00Z"
        )

        let result = HistoryManager.appendAndTrim(entry: newEntry, to: history, maxSize: 1)

        #expect(result.entries.count == 1, "Should have exactly 1 entry when maxSize is 1, got \(result.entries.count)")
        #expect(result.entries.first == newEntry, "The single entry should be the newly appended one")
    }
}
