import Logging

@testable import IcecastMetadataCollector
@testable import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Fake authorization provider returning a static header — never touches the network.
struct FakeAuthProvider: AuthorizationProvider {
    func authorizationHeader(logger: Logger) async throws -> [String: String] {
        ["Authorization": "Bearer test-token"]
    }
}

/// Fake Icecast reader that returns a preconfigured raw StreamTitle (or throws).
struct FakeIcecastReader: IcecastReading {
    let rawMetadata: String
    var error: (any Error)?

    func readMetadata(from streamURL: String, logger: Logger) async throws -> String {
        if let error { throw error }
        return rawMetadata
    }
}

/// Fake artwork downloader returning fixed bytes (or throwing) — records whether it was called.
final class FakeArtworkDownloader: ArtworkDownloading, @unchecked Sendable {
    let data: Data
    let error: (any Error)?
    private(set) var downloadCallCount = 0

    init(data: Data = Data("artwork-bytes".utf8), error: (any Error)? = nil) {
        self.data = data
        self.error = error
    }

    func download(artwork: Song.Attributes.Artwork, logger: Logger) async throws -> Data {
        downloadCallCount += 1
        if let error { throw error }
        return data
    }
}
