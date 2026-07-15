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

    private let awsClient: AWSClient
    private let ssm: SSM
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let region: Region

    private let logger: Logger

    public init(region: Region, awsProfileName: String? = nil, logger: Logger) throws {

        var logger = logger
        logger[metadataKey: "Component"] = "ParameterStoreManager"
        self.logger = logger

        self.region = region
        logger.trace("Using region: \(region)")

        // Build a soto AWSClient. This type owns the client because all callers
        // construct it standalone (one-shot CLI invocations and Lambda inits).
        // Those hosts are short-lived or reused across a warm Lambda process, so
        // we deliberately do not shut the client down here — the CLI process exits
        // and the Lambda process is reused, and adding an explicit shutdown would
        // break reuse. If a long-lived caller ever adopts this type, switch to an
        // injected AWSClient so the caller can manage its lifecycle.
        if let awsProfileName {
            logger.trace("Using credentials from AWS profile: \(awsProfileName)")
            self.awsClient = AWSClient(
                credentialProvider: .configFile(profile: awsProfileName)
            )
        } else {
            // Default provider chain (e.g. the Lambda execution role).
            self.awsClient = AWSClient()
        }

        self.ssm = SSM(
            client: self.awsClient,
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
