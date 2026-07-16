import HTTPTypes
public import Logging
public import Maxi80Backend
public import Routing

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// A request handler for a single HTTP endpoint.
///
/// The router calls these concretely, but conforming to `Action` lets the
/// compiler verify every action exposes the expected `handle` signature.
public protocol Action: Sendable {
    func handle(_ request: Routing.HTTPRequest, _ logger: Logger) async throws -> RouteResponse
}

/// Handles station information requests.
public struct StationAction: Action {
    public init() {}

    public func handle(_ request: Routing.HTTPRequest, _ logger: Logger) async throws -> RouteResponse {
        logger.debug("Handling station request")
        return .json(Station.default, statusCode: .ok)
    }
}

/// Handles artwork lookup requests by checking S3 for artwork existence and
/// returning a pre-signed URL if found.
public struct ArtworkAction: Action {
    private let s3Client: any S3ManagerProtocol
    private let bucket: String
    private let keyPrefix: String
    private let urlExpiration: TimeInterval

    public init(
        s3Client: any S3ManagerProtocol,
        bucket: String,
        keyPrefix: String,
        urlExpiration: TimeInterval
    ) {
        self.s3Client = s3Client
        self.bucket = bucket
        self.keyPrefix = keyPrefix
        self.urlExpiration = urlExpiration
    }

    public func handle(_ request: Routing.HTTPRequest, _ logger: Logger) async throws -> RouteResponse {
        logger.debug("Handling artwork request")

        // Missing parameters throw QueryParameterError, which the router maps to 400.
        let artist = try request.queryParameters.require("artist")
        let title = try request.queryParameters.require("title")

        let key = "\(keyPrefix)/\(artist)/\(title)/artwork.jpg"
        logger.debug("Looking up artwork key: \(key) in bucket: \(bucket)")

        let exists = try await s3Client.objectExists(bucket: bucket, key: key)

        guard exists else {
            logger.debug("Artwork not found, returning empty response")
            return .empty(statusCode: .noContent)
        }

        let url = try await s3Client.presignedGetURL(bucket: bucket, key: key, expiration: urlExpiration)
        return .json(ArtworkResponse(url: url), statusCode: .ok)
    }
}

/// Handles history requests by reading history.json from S3 and returning it directly.
public struct HistoryAction: Action {
    private let s3Client: any S3ManagerProtocol
    private let bucket: String
    private let keyPrefix: String

    public init(
        s3Client: any S3ManagerProtocol,
        bucket: String,
        keyPrefix: String
    ) {
        self.s3Client = s3Client
        self.bucket = bucket
        self.keyPrefix = keyPrefix
    }

    public func handle(_ request: Routing.HTTPRequest, _ logger: Logger) async throws -> RouteResponse {
        logger.debug("Handling history request")

        let jsonHeader = ["Content-Type": "application/json"]
        let key = "\(keyPrefix)/history.json"
        guard let data = try await s3Client.getObject(bucket: bucket, key: key) else {
            // No history file yet — return an empty entries array.
            return .string("{\"entries\":[]}", statusCode: .ok, headers: jsonHeader)
        }
        return .string(String(decoding: data, as: UTF8.self), statusCode: .ok, headers: jsonHeader)
    }
}

// MARK: - Artwork Response

/// JSON response model for the artwork endpoint.
public struct ArtworkResponse: Codable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
