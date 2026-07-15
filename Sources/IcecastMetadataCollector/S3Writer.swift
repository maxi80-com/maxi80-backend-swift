import Logging
import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Builds an S3 key from prefix, artist, title, and file name.
func buildS3Key(prefix: String, artist: String, title: String, file: String) -> String {
    "\(prefix)/\(artist)/\(title)/\(file)"
}

struct S3Config {
    let s3Client: any S3ManagerProtocol
    let bucket: String
    let keyPrefix: String
}

struct S3Writer {
    let config: S3Config

    /// Checks if metadata.json already exists for this artist/title combination.
    func exists(artist: String, title: String) async throws -> Bool {
        let key = buildS3Key(prefix: config.keyPrefix, artist: artist, title: title, file: "metadata.json")
        return try await config.s3Client.objectExists(bucket: config.bucket, key: key)
    }

    /// Reads the previously collected metadata.json for this artist/title, or nil if absent/undecodable.
    func readMetadata(artist: String, title: String) async throws -> CollectedMetadata? {
        let key = buildS3Key(prefix: config.keyPrefix, artist: artist, title: title, file: "metadata.json")
        guard let data = try await config.s3Client.getObject(bucket: config.bucket, key: key) else {
            return nil
        }
        return try? JSONDecoder().decode(CollectedMetadata.self, from: data)
    }

    func writeMetadata(_ metadata: CollectedMetadata, artist: String, title: String, logger: Logger) async throws {
        let key = buildS3Key(prefix: config.keyPrefix, artist: artist, title: title, file: "metadata.json")
        let data: Data
        do {
            data = try JSONEncoder().encode(metadata)
        } catch {
            throw CollectorError.s3WriteFailed(file: "metadata.json", reason: "\(error)")
        }
        try await putObject(
            data: data,
            key: key,
            contentType: "application/json",
            file: "metadata.json",
            logger: logger
        )
    }

    func writeSearchResults(_ data: Data, artist: String, title: String, logger: Logger) async throws {
        let key = buildS3Key(prefix: config.keyPrefix, artist: artist, title: title, file: "search.json")
        try await putObject(data: data, key: key, contentType: "application/json", file: "search.json", logger: logger)
    }

    func writeArtwork(_ data: Data, artist: String, title: String, logger: Logger) async throws {
        let key = buildS3Key(prefix: config.keyPrefix, artist: artist, title: title, file: "artwork.jpg")
        try await putObject(data: data, key: key, contentType: "image/jpeg", file: "artwork.jpg", logger: logger)
    }

    /// Server-side copies one of the per-track files from a source title to a destination title
    /// (same artist), used to migrate legacy stripped-title cache objects to the full-title key.
    func copyFile(_ file: String, artist: String, fromTitle: String, toTitle: String, logger: Logger) async throws {
        let fromKey = buildS3Key(prefix: config.keyPrefix, artist: artist, title: fromTitle, file: file)
        let toKey = buildS3Key(prefix: config.keyPrefix, artist: artist, title: toTitle, file: file)
        logger.debug("Copying \(file) s3://\(config.bucket)/\(fromKey) → \(toKey)")
        try await config.s3Client.copyObject(bucket: config.bucket, fromKey: fromKey, toKey: toKey)
    }

    /// Deletes one of the per-track files for a given title, used to remove legacy stripped-title
    /// cache objects after they've been copied to the full-title key.
    func deleteFile(_ file: String, artist: String, title: String, logger: Logger) async throws {
        let key = buildS3Key(prefix: config.keyPrefix, artist: artist, title: title, file: file)
        logger.debug("Deleting s3://\(config.bucket)/\(key)")
        try await config.s3Client.deleteObject(bucket: config.bucket, key: key)
    }

    private func putObject(data: Data, key: String, contentType: String, file: String, logger: Logger) async throws {
        logger.debug("Writing \(file) to s3://\(config.bucket)/\(key)")
        do {
            try await config.s3Client.putObject(data: data, bucket: config.bucket, key: key, contentType: contentType)
        } catch {
            logger.error("S3 PutObject failed for \(file): \(String(describing: error))")
            throw CollectorError.s3WriteFailed(file: file, reason: "\(error)")
        }
    }
}
