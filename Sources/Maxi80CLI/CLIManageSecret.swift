import ArgumentParser
import Logging
import Maxi80Backend
import SotoCore

struct StoreSecrets: AsyncParsableCommand {

    @OptionGroup var globalOptions: GlobalOptions

    public func run() async throws {
        let logger = GlobalOptions.logger(verbose: globalOptions.verbose)
        // Secret() lives in a separate file not saved to git
        let version = try await globalOptions.withAWSClient { awsClient in
            let parameterStore = ParameterStoreManager<AppleMusicSecret>(
                client: awsClient,
                region: globalOptions.region,
                logger: logger
            )
            return try await parameterStore.storeSecret(secret: Secret.appleMusicSecret, parameterName: Secret.name)
        }
        print("✅ your secret is stored. Version = \(version)")
    }
}

struct GetSecrets: AsyncParsableCommand {

    @OptionGroup var globalOptions: GlobalOptions

    public func run() async throws {

        let logger = GlobalOptions.logger(verbose: globalOptions.verbose)
        // Secret() lives in a separate file not saved to git
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
