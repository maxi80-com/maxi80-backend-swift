import ArgumentParser
import Logging
import Maxi80Backend
import SotoCore
import Synchronization

// arguments that are global to all commands
struct GlobalOptions: ParsableArguments {

    @Flag(name: .shortAndLong, help: "Produce verbose output for debugging")
    var verbose = false

    @Option(name: .shortAndLong, help: "The AWS Region where the secrets are stored")
    var region = Region.eucentral1

    @Option(
        name: .shortAndLong,
        help:
            "The AWS CLI profile name to use for AWS credentials. When not provided, it uses the standard credentials provider chain to locate credentials."
    )
    var profile: String? = nil

    private static let _logger = Logger(label: "Maxi80CLI")
    static func logger(verbose: Bool) -> Logger {
        var logger = _logger
        if verbose {
            logger.logLevel = .trace
        } else {
            logger.logLevel = .info
        }
        return logger
    }
}
