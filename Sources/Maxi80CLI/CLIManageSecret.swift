import ArgumentParser
import Logging
import Maxi80Backend
import SotoCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct StoreSecrets: AsyncParsableCommand {

    @OptionGroup var globalOptions: GlobalOptions

    @Option(name: .shortAndLong, help: "Path to the JSON key file to store in SSM Parameter Store")
    var keyFile: String

    public func run() async throws {
        let logger = GlobalOptions.logger(verbose: globalOptions.verbose)

        let data = try Data(contentsOf: URL(fileURLWithPath: keyFile))
        let secret = try JSONDecoder().decode(AppleMusicSecret.self, from: data)

        let version = try await globalOptions.withAWSClient { awsClient in
            let parameterStore = ParameterStoreManager<AppleMusicSecret>(
                client: awsClient,
                region: globalOptions.region,
                logger: logger
            )
            return try await parameterStore.storeSecret(secret: secret, parameterName: Secret.name)
        }
        print("✅ your secret is stored. Version = \(version)")
    }
}

struct GetSecrets: AsyncParsableCommand {

    @OptionGroup var globalOptions: GlobalOptions

    public func run() async throws {

        let logger = GlobalOptions.logger(verbose: globalOptions.verbose)
        let secret = try await globalOptions.withAWSClient { awsClient in
            let parameterStore = ParameterStoreManager<AppleMusicSecret>(
                client: awsClient,
                region: globalOptions.region,
                logger: logger
            )
            return try await parameterStore.getSecret(parameterName: Secret.name)
        }
        print("✅ your secret is \(secret)")
    }
}
