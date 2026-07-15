import AsyncHTTPClient
import Logging
import Maxi80Backend
import NIOCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Downloads artwork image data for a matched song. Abstracted for dependency injection.
protocol ArtworkDownloading: Sendable {
    func download(artwork: Song.Attributes.Artwork, logger: Logger) async throws -> Data
}

struct ArtworkDownloader: ArtworkDownloading {

    func download(artwork: Song.Attributes.Artwork, logger: Logger) async throws -> Data {
        let urlString = buildArtworkURL(
            template: artwork.url, width: artwork.width, height: artwork.height
        )

        logger.debug("Downloading artwork from: \(urlString)")

        var request = HTTPClientRequest(url: urlString)
        request.headers.add(name: "User-Agent", value: "maxi80/1.0")

        let response: HTTPClientResponse
        do {
            response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
        } catch {
            throw CollectorError.artworkDownloadFailed(reason: error.localizedDescription)
        }

        guard response.status == .ok else {
            throw CollectorError.artworkDownloadFailed(reason: "HTTP \(response.status.code)")
        }

        guard let bytes = try? await response.body.collect(upTo: 10 * 1024 * 1024)  // 10MB max
        else {        
            throw CollectorError.artworkDownloadFailed(reason: "Empty response body")
        }
        return Data(bytes.readableBytesView)
    }

    /// Builds the artwork download URL by replacing {w} and {h} placeholders.
    func buildArtworkURL(template: String, width: Int, height: Int) -> String {
        template
            .replacingOccurrences(of: "{w}", with: "\(width)")
            .replacingOccurrences(of: "{h}", with: "\(height)")
    }
}
