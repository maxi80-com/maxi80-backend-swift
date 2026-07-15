import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Reads the current track metadata from an Icecast stream. Abstracted for dependency injection.
protocol IcecastReading: Sendable {
    func readMetadata(from streamURL: String, logger: Logger) async throws -> String
}

struct IcecastReader: IcecastReading {

    /// Connects to an Icecast stream and extracts the first non-empty StreamTitle metadata.
    func readMetadata(from streamURL: String, logger: Logger) async throws -> String {
        let request = buildRequest(for: streamURL)

        logger.debug("Connecting to Icecast stream: \(streamURL)")

        let response: HTTPClientResponse
        do {
            response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
        } catch {
            throw IcecastError.connectionFailed(reason: "\(error)")
        }

        guard response.status == .ok || response.status.code < 400 else {
            throw IcecastError.connectionFailed(
                reason: "HTTP \(response.status.code): \(response.status.reasonPhrase)"
            )
        }

        guard let metaIntString = response.headers.first(name: "icy-metaint"),
            let metaInt = Int(metaIntString),
            metaInt > 0
        else {
            throw IcecastError.missingMetaInt
        }

        logger.debug("icy-metaint: \(metaInt)")

        // Accumulate all bytes from the async stream, then parse
        var allBytes: [UInt8] = []

        for try await var chunk in response.body {
            let bytes = chunk.readBytes(length: chunk.readableBytes) ?? []
            allBytes.append(contentsOf: bytes)

            // Try to parse metadata from what we have so far
            if let title = parseMetadataFromStream(
                buffer: allBytes,
                metaInt: metaInt
            ) {
                logger.debug("Extracted StreamTitle: \(title)")
                return title
            }
        }

        throw IcecastError.noMetadata
    }

    /// Builds an HTTP request with the Icy-MetaData header for the given stream URL.
    func buildRequest(for streamURL: String) -> HTTPClientRequest {
        var request = HTTPClientRequest(url: streamURL)
        request.headers.add(name: "Icy-MetaData", value: "1")
        request.headers.add(name: "User-Agent", value: "maxi80-metadata-collector/2.0")
        return request
    }

    /// Extracts the StreamTitle value from an Icecast metadata string.
    /// Expected format: `StreamTitle='Some Title';`
    func extractStreamTitle(_ metadata: String) -> String? {
        let prefix = "StreamTitle='"
        guard let prefixRange = metadata.firstRange(of: prefix) else {
            return nil
        }
        let afterPrefix = metadata[prefixRange.upperBound...]
        guard let endQuote = afterPrefix.firstRange(of: "';") else {
            return nil
        }
        let value = String(afterPrefix[..<endQuote.lowerBound])
        return value.isEmpty ? nil : value
    }

    /// Parses metadata from a raw Icecast byte stream buffer.
    /// Returns the first non-empty StreamTitle found, or nil if not enough data.
    func parseMetadataFromStream(buffer: [UInt8], metaInt: Int) -> String? {
        var offset = 0

        while offset < buffer.count {
            // Skip audio bytes
            let audioEnd = offset + metaInt
            guard audioEnd < buffer.count else {
                // Not enough data to reach the length byte yet
                return nil
            }

            // Read the length byte
            let lengthByte = Int(buffer[audioEnd])
            let metadataLength = lengthByte * 16
            let metadataStart = audioEnd + 1

            if metadataLength == 0 {
                // Empty metadata block, skip to next audio segment
                offset = metadataStart
                continue
            }

            let metadataEnd = metadataStart + metadataLength
            guard metadataEnd <= buffer.count else {
                // Not enough data to read the full metadata block
                return nil
            }

            // Extract metadata bytes and decode as UTF-8
            let metadataBytes = Array(buffer[metadataStart..<metadataEnd])
            // Trim null padding bytes
            let trimmedBytes = metadataBytes.prefix(while: { $0 != 0 })
            let metadataString = String(bytes: trimmedBytes, encoding: .utf8) ?? ""

            if let title = extractStreamTitle(metadataString), !title.isEmpty {
                return title
            }

            // Move past this metadata block to the next audio segment
            offset = metadataEnd
        }

        return nil
    }
}
