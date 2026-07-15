public import AWSS3
import Logging
import Smithy

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - S3 Client Protocol

/// Protocol abstracting S3 operations, enabling testability via mocks.
public protocol S3ManagerProtocol: Sendable {
    /// Check if an object exists at the given bucket/key.
    /// Returns true if exists, false if not found.
    /// Throws for unexpected S3 errors.
    func objectExists(bucket: String, key: String) async throws -> Bool

    /// Generate a pre-signed GetObject URL for the given bucket/key with the specified expiration.
    func presignedGetURL(bucket: String, key: String, expiration: TimeInterval) async throws -> URL

    /// Upload data to S3 at the given bucket/key with the specified content type.
    func putObject(data: Data, bucket: String, key: String, contentType: String) async throws

    /// Download an object from S3. Returns nil if the key does not exist (NoSuchKey).
    func getObject(bucket: String, key: String) async throws -> Data?

    /// Server-side copy an object within the same bucket from one key to another.
    func copyObject(bucket: String, fromKey: String, toKey: String) async throws

    /// Delete an object. Succeeds (no-op) if the key does not exist.
    func deleteObject(bucket: String, key: String) async throws
}

// MARK: - AWS S3 Client Adapter

/// Concrete implementation wrapping `AWSS3.S3Client`.
public struct S3Manager: S3ManagerProtocol, Sendable {
    private let s3Client: S3Client
    private let region: Region

    public init(s3Client: S3Client, region: Region) {
        self.s3Client = s3Client
        self.region = region
    }

    public func objectExists(bucket: String, key: String) async throws -> Bool {
        do {
            _ = try await s3Client.headObject(input: HeadObjectInput(bucket: bucket, key: key))
            return true
        } catch is AWSS3.NotFound {
            return false
        }
        // Other errors propagate — caller logs the details
    }

    public func presignedGetURL(bucket: String, key: String, expiration: TimeInterval) async throws -> URL {
        let input = GetObjectInput(bucket: bucket, key: key)
        let config = try await S3Client.S3ClientConfig(region: region.rawValue)
        guard let url = try await input.presignURL(config: config, expiration: expiration) else {
            throw S3ManagerError.presignFailed(key: key)
        }
        return url
    }

    public func putObject(data: Data, bucket: String, key: String, contentType: String) async throws {
        _ = try await s3Client.putObject(
            input: PutObjectInput(
                body: .data(data),
                bucket: bucket,
                contentType: contentType,
                key: key
            )
        )
    }

    public func getObject(bucket: String, key: String) async throws -> Data? {
        do {
            let output = try await s3Client.getObject(input: GetObjectInput(bucket: bucket, key: key))
            guard let body = output.body,
                let data = try await body.readData()
            else {
                return nil
            }
            return data
        } catch is AWSS3.NoSuchKey {
            return nil
        }
    }

    public func copyObject(bucket: String, fromKey: String, toKey: String) async throws {
        // CopySource must be URL-encoded and include the bucket: "bucket/key".
        let source = "\(bucket)/\(fromKey)".addingPathPercentEncoding()
        _ = try await s3Client.copyObject(
            input: CopyObjectInput(
                bucket: bucket,
                copySource: source,
                key: toKey
            )
        )
    }

    public func deleteObject(bucket: String, key: String) async throws {
        _ = try await s3Client.deleteObject(input: DeleteObjectInput(bucket: bucket, key: key))
    }
}

/// Errors specific to the S3 manager.
public enum S3ManagerError: Error {
    case presignFailed(key: String)
}

// MARK: - Bucket Region Resolution

/// Resolves the actual AWS region of an S3 bucket by calling GetBucketLocation.
/// Falls back to `fallback` if the lookup fails.
///
/// Note: GetBucketLocation must be called against us-east-1 (the S3 global endpoint)
/// to reliably work for buckets in any region.
///
/// - Parameters:
///   - bucket: The S3 bucket name.
///   - configuredRegion: The region to use as fallback if the lookup fails.
///   - fallback: The region to return if the lookup fails. Defaults to `configuredRegion`.
/// - Returns: The resolved bucket region.
public func resolveBucketRegion(
    bucket: String,
    configuredRegion: Region,
    fallback: Region? = nil
) async -> Region {
    do {
        // GetBucketLocation must be called from us-east-1 to work for any bucket
        let tempConfig = try S3Client.S3ClientConfig(region: "us-east-1")
        let tempS3 = S3Client(config: tempConfig)
        let locationOutput = try await tempS3.getBucketLocation(
            input: GetBucketLocationInput(bucket: bucket)
        )
        if let locationConstraint = locationOutput.locationConstraint?.rawValue,
            !locationConstraint.isEmpty
        {
            return Region(rawValue: locationConstraint)
        } else {
            // Buckets in us-east-1 return nil/empty LocationConstraint
            return .useast1
        }
    } catch {
        return fallback ?? configuredRegion
    }
}
