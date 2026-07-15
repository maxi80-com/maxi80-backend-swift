import AWSSDKIdentity
import AWSSSM
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

    private let ssmClient: SSMClient
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let region: Region

    private let logger: Logger

    public init(region: Region, awsProfileName: String? = nil, logger: Logger) throws {

        var logger = logger
        logger[metadataKey: "Component"] = "ParameterStoreManager"
        self.logger = logger

        // create an SSM configuration
        self.region = region
        guard
            var config = try? SSMClient.SSMClientConfig(
                region: region.rawValue
            )
        else {
            throw ParameterStoreError.cannotCreateClient(
                reason: "Failed to create SSM configuration"
            )
        }
        logger.trace("Using region: \(region)")

        if let awsProfileName {
            logger.trace("Using credentials from AWS profile: \(awsProfileName)")
            config.awsCredentialIdentityResolver = ProfileAWSCredentialIdentityResolver(
                profileName: awsProfileName
            )
        }

        // Configure SSM client
        self.ssmClient = SSMClient(config: config)
    }

    public func getSecret(parameterName: String) async throws -> S {

        // Create GetParameter request with decryption
        let request = GetParameterInput(name: parameterName, withDecryption: true)

        // Get the parameter value
        logger.trace("Retrieving parameter: \(parameterName)")
        let response: GetParameterOutput
        do {
            response = try await self.ssmClient.getParameter(input: request)
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
        let request = PutParameterInput(
            name: parameterName,
            overwrite: true,
            type: .secureString,
            value: secretString
        )

        let response: PutParameterOutput
        do {
            response = try await self.ssmClient.putParameter(input: request)
        } catch {
            logger.error("Cannot store parameter")
            throw ParameterStoreError.backendError(rootcause: error)
        }

        let version = Int(response.version)
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
