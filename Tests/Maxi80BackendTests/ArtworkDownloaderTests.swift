import Testing

@testable import IcecastMetadataCollector

@Suite("Artwork Downloader Tests")
struct ArtworkDownloaderTests {

    let downloader = ArtworkDownloader()

    struct ArtworkURLTestCase: CustomStringConvertible, Sendable {
        let template: String
        let width: Int
        let height: Int
        var description: String { "template='\(template)', width=\(width), height=\(height)" }
    }

    static func generateArtworkURLTestCases(count: Int) -> [ArtworkURLTestCase] {
        var rng = SystemRandomNumberGenerator()
        let alphanumeric = Array("abcdefghijklmnopqrstuvwxyz0123456789")

        return (0..<count).map { _ in
            let pathLength = Int.random(in: 5...30, using: &rng)
            let path = String(
                (0..<pathLength).map { _ in alphanumeric[Int.random(in: 0..<alphanumeric.count, using: &rng)] }
            )
            let template = "https://example.com/\(path)/{w}x{h}bb.jpg"
            let width = Int.random(in: 1...10000, using: &rng)
            let height = Int.random(in: 1...10000, using: &rng)
            return ArtworkURLTestCase(template: template, width: width, height: height)
        }
    }

    // Feature: icecast-metadata-collector, Property 5: Artwork URL template substitution
    /// **Validates: Requirements 5.1**
    @Test(
        "Property 5: Artwork URL template substitution",
        arguments: generateArtworkURLTestCases(count: 100)
    )
    func artworkURLTemplateSubstitution(testCase: ArtworkURLTestCase) {
        let result = downloader.buildArtworkURL(
            template: testCase.template,
            width: testCase.width,
            height: testCase.height
        )

        #expect(!result.contains("{w}"), "URL should not contain {w} placeholder")
        #expect(!result.contains("{h}"), "URL should not contain {h} placeholder")
        #expect(result.contains("\(testCase.width)"), "URL should contain width value")
        #expect(result.contains("\(testCase.height)"), "URL should contain height value")
    }
}

// MARK: - Unit Tests

extension ArtworkDownloaderTests {

    @Test("buildArtworkURL handles multiple placeholder occurrences")
    func buildArtworkURLMultiplePlaceholders() {
        let template = "https://example.com/{w}x{h}/{w}x{h}bb.jpg"
        let result = downloader.buildArtworkURL(template: template, width: 500, height: 600)
        #expect(result == "https://example.com/500x600/500x600bb.jpg")
        #expect(!result.contains("{w}"))
        #expect(!result.contains("{h}"))
    }

    @Test("buildArtworkURL returns unchanged URL when no placeholders")
    func buildArtworkURLNoPlaceholders() {
        let template = "https://example.com/image/fixed.jpg"
        let result = downloader.buildArtworkURL(template: template, width: 100, height: 200)
        #expect(result == "https://example.com/image/fixed.jpg")
    }

    @Test("CollectorError.artworkDownloadFailed carries reason")
    func artworkDownloadFailedError() {
        let error = CollectorError.artworkDownloadFailed(reason: "HTTP 404")
        if case .artworkDownloadFailed(let reason) = error {
            #expect(reason == "HTTP 404")
        } else {
            Issue.record("Expected artworkDownloadFailed error")
        }
    }
}
