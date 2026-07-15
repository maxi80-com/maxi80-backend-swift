public import SotoCore
import SotoSSM
public import Logging

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Parameter Store Protocol

/// Protocol abstracting parameter store operations, enabling testability via mocks.
public protocol ParameterStoreProtocol {
    associatedtype S: Codable

    /// Retrieve and decode a SecureString parameter by name.
    func getSecret(parameterName: String) async throws -> S

    /// Store (or update) a SecureString parameter by name. Returns the parameter version.
    func storeSecret(secret: S, parameterName: String) async throws -> Int
}

// MARK: - Parameter Store Manager

public struct ParameterStoreManager<S: Codable>: ParameterStoreProtocol {

    private let ssm: SSM
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let region: Region

    private let logger: Logger

    /// - Parameter client: The soto `AWSClient` to use. The CALLER owns its lifecycle (creation
    ///   and shutdown); this type never shuts it down. Injecting the client — rather than creating
    ///   one internally — lets the caller manage graceful shutdown and avoids soto's debug-build
    ///   `deinit` assertion that fires when an `AWSClient` is released without `syncShutdown()`.
    public init(client: AWSClient, region: Region, logger: Logger) {

        var logger = logger
        logger[metadataKey: "Component"] = "ParameterStoreManager"
        self.logger = logger

        self.region = region
        logger.trace("Using region: \(region)")

        self.ssm = SSM(
            client: client,
            region: SotoCore.Region(rawValue: region.rawValue)
        )
    }

    public func getSecret(parameterName: String) async throws -> S {

        // Get the parameter value (with decryption for SecureString parameters)
        logger.trace("Retrieving parameter: \(parameterName)")
        let response: SSM.GetParameterResult
        do {
            response = try await self.ssm.getParameter(
                SSM.GetParameterRequest(name: parameterName, withDecryption: true)
            )
        } catch {
            throw ParameterStoreError.backendError(rootcause: error)
        }
        logger.trace("Parameter retrieved")

        // Decode JSON data
        guard let value = response.parameter?.value else {
            throw ParameterStoreError.decodingFailed(reason: "Failed to decode parameter value")
        }

        let decodedData = try decoder.decode(S.self, from: Data(value.utf8))

        logger.trace("Parameter decoded")
        return decodedData
    }

    public func storeSecret(secret: S, parameterName: String) async throws -> Int {
        let data = try encoder.encode(secret)
        let secretString = String(decoding: data, as: UTF8.self)

        logger.trace("Storing parameter: \(parameterName)")

        let response: SSM.PutParameterResult
        do {
            response = try await self.ssm.putParameter(
                SSM.PutParameterRequest(
                    name: parameterName,
                    overwrite: true,
                    type: .secureString,
                    value: secretString
                )
            )
        } catch {
            logger.error("Cannot store parameter")
            throw ParameterStoreError.backendError(rootcause: error)
        }

        let version = Int(response.version ?? 0)
        logger.trace("Parameter stored (version \(version))")
        return version
    }
}

// Define Parameter Store error enum for clarity
enum ParameterStoreError: Error {
    case decodingFailed(reason: String)
    case cannotCreateClient(reason: String)
    case invalidResponse(reason: String)
    case backendError(rootcause: any Error)
}
