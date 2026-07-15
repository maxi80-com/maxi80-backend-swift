public import ArgumentParser
import Logging
public import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct Search: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "Search Apple Music for artists, albums, and songs"
    )

    @OptionGroup var globalOptions: GlobalOptions

    @Argument(help: "The search term to look for")
    var term: String

    @Option(help: "Search types to include (artists, albums, songs). Default: all")
    var types: [AppleMusicSearchType] = [.artists, .albums, .songs]

    public func run() async throws {
        let logger = GlobalOptions.logger(verbose: globalOptions.verbose)

        // Initialize HTTP client
        let httpClient = MusicAPIClient()

        // Get Apple Music credentials from parameter store
        let parameterStore = try ParameterStoreManager<AppleMusicSecret>(
            region: globalOptions.region,
            awsProfileName: globalOptions.profile,
            logger: logger
        )

        let secret = try await parameterStore.getSecret(parameterName: Secret.name)
        logger.trace("Got secret \(secret)")

        let tokenFactory = JWTTokenFactory(
            secretKey: secret.privateKey,
            keyId: secret.keyId,
            issuerId: secret.teamId
        )
        logger.trace("Token: \(tokenFactory)")

        // Get authorization header
        let authHeader = try await authorizationHeader(tokenFactory: tokenFactory, logger: logger)
        logger.trace("Header: \(authHeader)")

        // Perform the search
        let searchFields = AppleMusicSearchType.items(searchTypes: types)
        logger.trace("searchFields: \(searchFields)")
        let searchTerms = AppleMusicSearchType.term(search: term)
        logger.trace("searchTerms: \(searchTerms)")

        logger.info("Searching Apple Music for: '\(term)'")
        logger.trace("Search types: \(types.map { $0.rawValue }.joined(separator: ", "))")

        logger.trace("Calling the Music API")
        let (data, _) = try await httpClient.apiCall(
            url: AppleMusicEndpoint.search.url(args: [searchFields, searchTerms]),
            headers: authHeader,
            logger: logger
        )

        // Parse the Apple Music search response
        logger.trace("Preparing the output for pretty printing")
        do {
            let decoder = JSONDecoder()
            let searchResponse = try decoder.decode(AppleMusicSearchResponse.self, from: data)

            // Pretty print the structured response
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let prettyData = try encoder.encode(searchResponse)

            if let prettyString = String(data: prettyData, encoding: .utf8) {
                print(prettyString)
            } else {
                print(String(data: data, encoding: .utf8) ?? "Unable to decode response")
            }
        } catch {
            logger.error("Failed to parse Apple Music response: \(error)")
            // Fallback to raw string output if JSON parsing fails
            print(String(data: data, encoding: .utf8) ?? "Unable to decode response")
        }
    }

    private func authorizationHeader(tokenFactory: JWTTokenFactory, logger: Logger) async throws -> [String: String] {
        // Generate a new auth token for each request
        logger.debug("Generating new Apple Music Auth Token")
        let token = try await tokenFactory.generateJWTString()
        return ["Authorization": "Bearer \(token)"]
    }
}

// Extension to make AppleMusicSearchType work with ArgumentParser
extension AppleMusicSearchType: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}
