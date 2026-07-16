import Logging
public import SotoCore
import SotoS3

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

// MARK: - Soto S3 Client Adapter

/// Concrete implementation wrapping Soto's `S3` service.
public struct S3Manager: S3ManagerProtocol, Sendable {
    /// Maximum size (bytes) collected from a GetObject response body.
    private static let maxObjectSize = 20 * 1024 * 1024

    private let client: AWSClient
    private let s3: S3
    private let region: Region

    public init(client: AWSClient, region: Region) {
        self.client = client
        self.region = region
        self.s3 = S3(client: client, region: SotoCore.Region(rawValue: region.rawValue))
    }

    public func objectExists(bucket: String, key: String) async throws -> Bool {
        do {
            _ = try await s3.headObject(bucket: bucket, key: key)
            return true
        } catch let error as S3ErrorType where error == .notFound || error == .noSuchKey {
            return false
        } catch let error as AWSResponseError where error.context?.responseCode == .notFound {
            // HeadObject returns a bodyless 404 that surfaces as an unmodeled response
            // error rather than a typed S3ErrorType.
            return false
        }
        // Other errors propagate — caller logs the details
    }

    public func presignedGetURL(bucket: String, key: String, expiration: TimeInterval) async throws -> URL {
        // Use PATH-style (bucket in the path, not the host). The bucket name "artwork.maxi80.com"
        // contains dots, so virtual-hosted style (`<bucket>.s3.<region>.amazonaws.com`) yields a
        // host the S3 wildcard cert `*.s3.<region>.amazonaws.com` can't match → the client's TLS
        // trust evaluation fails (-9802). Path-style keeps the host at `s3.<region>.amazonaws.com`.
        let encodedKey = key.addingPathPercentEncoding()
        guard let url = URL(string: "https://s3.\(region.rawValue).amazonaws.com/\(bucket)/\(encodedKey)") else {
            throw S3ManagerError.presignFailed(key: key)
        }
        return try await client.signURL(
            url: url,
            httpMethod: .GET,
            expires: .seconds(Int64(expiration)),
            serviceConfig: s3.config
        )
    }

    public func putObject(data: Data, bucket: String, key: String, contentType: String) async throws {
        _ = try await s3.putObject(
            S3.PutObjectRequest(
                body: .init(bytes: data),
                bucket: bucket,
                contentType: contentType,
                key: key
            )
        )
    }

    public func getObject(bucket: String, key: String) async throws -> Data? {
        do {
            let output = try await s3.getObject(bucket: bucket, key: key)
            let buffer = try await output.body.collect(upTo: Self.maxObjectSize)
            return Data(buffer.readableBytesView)
        } catch let error as S3ErrorType where error == .noSuchKey || error == .notFound {
            return nil
        } catch let error as AWSResponseError where error.context?.responseCode == .notFound {
            return nil
        } catch let error as any AWSErrorType where error.context?.responseCode == .notFound {
            // Defensive: any Soto error carrying a 404 response is a cache miss, regardless of the
            // concrete type. Keeps a missing object returning nil even if Soto surfaces the 404 as
            // a type not matched above. A non-404 error (auth, throttling, transport) still throws.
            return nil
        }
    }

    public func copyObject(bucket: String, fromKey: String, toKey: String) async throws {
        // CopySource must be URL-encoded and include the bucket: "bucket/key".
        let source = "\(bucket)/\(fromKey)".addingPathPercentEncoding()
        _ = try await s3.copyObject(
            S3.CopyObjectRequest(
                bucket: bucket,
                copySource: source,
                key: toKey
            )
        )
    }

    public func deleteObject(bucket: String, key: String) async throws {
        _ = try await s3.deleteObject(bucket: bucket, key: key)
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
///   - client: The shared `AWSClient` used to issue the request.
///   - configuredRegion: The region to use as fallback if the lookup fails.
///   - fallback: The region to return if the lookup fails. Defaults to `configuredRegion`.
/// - Returns: The resolved bucket region.
public func resolveBucketRegion(
    bucket: String,
    client: AWSClient,
    configuredRegion: Region,
    fallback: Region? = nil
) async -> Region {
    do {
        // GetBucketLocation must be called from us-east-1 to work for any bucket
        let s3 = S3(client: client, region: .useast1)
        let locationOutput = try await s3.getBucketLocation(bucket: bucket)
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
