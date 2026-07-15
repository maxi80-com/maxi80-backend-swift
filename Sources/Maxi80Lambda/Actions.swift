public import AWSLambdaEvents
public import HTTPTypes
public import Logging
public import Maxi80Backend

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// Protocol for all action handlers
public protocol Action {
    /// The endpoint path this action handles
    var endpoint: Maxi80Endpoint { get }

    /// The HTTP method this action handles
    var method: HTTPRequest.Method { get }

    /// Handle the request
    func handle(event: APIGatewayV2Request, logger: Logger) async throws -> Data
}

/// Handles station information requests
public struct StationAction: Action {
    public let endpoint: Maxi80Endpoint = .station
    public let method: HTTPRequest.Method = .get

    public init() {}

    public func handle(event: APIGatewayV2Request, logger: Logger) async throws -> Data {
        logger.debug("Handling station request")
        let station = Station.default
        return try encode(station)
    }

    private func encode<T: Encodable>(_ data: T) throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(data)
    }
}

/// Handles artwork lookup requests by checking S3 for artwork existence
/// and returning a pre-signed URL if found.
public struct ArtworkAction: Action {
    public let endpoint: Maxi80Endpoint = .artwork
    public let method: HTTPRequest.Method = .get

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

    public func handle(event: APIGatewayV2Request, logger: Logger) async throws -> Data {
        logger.debug("Handling artwork request")

        guard let artist = event.queryStringParameters["artist"] else {
            throw ActionError.missingParameter(name: "artist")
        }
        guard let title = event.queryStringParameters["title"] else {
            throw ActionError.missingParameter(name: "title")
        }

        let key = "\(keyPrefix)/\(artist)/\(title)/artwork.jpg"
        logger.debug("Looking up artwork key: \(key) in bucket: \(bucket)")

        let exists: Bool
        do {
            exists = try await s3Client.objectExists(bucket: bucket, key: key)
        } catch {
            let errorType = String(describing: type(of: error))
            let errorDesc = String(describing: error)
            logger.debug("objectExists failed — type: \(errorType), description: \(errorDesc)")
            throw error
        }

        guard exists else {
            logger.debug("Artwork not found, returning empty response")
            return Data()
        }

        let url = try await s3Client.presignedGetURL(bucket: bucket, key: key, expiration: urlExpiration)
        let response = ArtworkResponse(url: url)
        return try JSONEncoder().encode(response)
    }
}

/// Action-specific errors
public enum ActionError: Error, CustomStringConvertible {
    case missingParameter(name: String)
    case invalidParameter(name: String, reason: String)

    public var description: String {
        switch self {
        case .missingParameter(let name):
            return "Missing required parameter: \(name)"
        case .invalidParameter(let name, let reason):
            return "Invalid parameter '\(name)': \(reason)"
        }
    }
}

// MARK: - History Action

/// Handles history requests by reading history.json from S3 and returning it directly.
public struct HistoryAction: Action {
    public let endpoint: Maxi80Endpoint = .history
    public let method: HTTPRequest.Method = .get

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

    public func handle(event: APIGatewayV2Request, logger: Logger) async throws -> Data {
        logger.debug("Handling history request")

        let key = "\(keyPrefix)/history.json"
        guard let data = try await s3Client.getObject(bucket: bucket, key: key) else {
            // No history file yet — return an empty entries array
            return Data("{\"entries\":[]}".utf8)
        }
        return data
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
