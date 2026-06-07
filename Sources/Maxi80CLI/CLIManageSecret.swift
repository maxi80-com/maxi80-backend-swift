import ArgumentParser
import Logging
import Maxi80Backend

struct StoreSecrets: AsyncParsableCommand {

    @OptionGroup var globalOptions: GlobalOptions

    public func run() async throws {
        let logger = GlobalOptions.logger(verbose: globalOptions.verbose)
        let parameterStore = try ParameterStoreManager<AppleMusicSecret>(
            region: globalOptions.region,
            awsProfileName: globalOptions.profile,
            logger: logger
        )

        // Secret() lives in a separate file not saved to git
        let version = try await parameterStore.storeSecret(secret: Secret.appleMusicSecret, parameterName: Secret.name)
        print("✅ your secret is stored. Version = \(version)")
    }
}

struct GetSecrets: AsyncParsableCommand {

    @OptionGroup var globalOptions: GlobalOptions

    public func run() async throws {

        let logger = GlobalOptions.logger(verbose: globalOptions.verbose)
        let parameterStore = try ParameterStoreManager<AppleMusicSecret>(
            region: globalOptions.region,
            awsProfileName: globalOptions.profile,
            logger: logger
        )

        // Secret() lives in a separate file not saved to git
        let secret = try await parameterStore.getSecret(parameterName: Secret.name)
        print("✅ your secret is \(secret)")
    }
}
