import AWSLambdaEvents
import AWSLambdaRuntime
import AWSS3
import Logging
import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@main
struct IcecastMetadataCollector: LambdaHandler {

    private let collector: MetadataCollector

    init() async throws {
        let loggingConfig = LoggingConfiguration(logger: Logger(label: "IcecastMetadataCollector"))
        let logger = loggingConfig.makeRuntimeLogger()

        // Read required environment variables
        guard let streamURL = Lambda.env("STREAM_URL") else {
            throw CollectorError.missingEnvironmentVariable("STREAM_URL")
        }

        guard let bucket = Lambda.env("S3_BUCKET") else {
            throw CollectorError.missingEnvironmentVariable("S3_BUCKET")
        }

        let keyPrefix = Lambda.env("KEY_PREFIX") ?? "collected"
        let secretName = Lambda.env("SECRETS") ?? "/maxi80/apple-music-key"

        // Read the region from the environment variable
        let configuredRegion = Lambda.env("AWS_REGION").flatMap { Region(awsRegionName: $0) } ?? .eucentral1
        logger.trace("Configured region: \(configuredRegion)")

        // Resolve bucket region and retrieve Apple Music secret in parallel.
        // These two async operations are independent — both only need env-derived values.

        async let resolvedBucketRegion: Region = resolveBucketRegion(
            bucket: bucket, configuredRegion: configuredRegion
        )

        async let resolvedTokenFactory: JWTTokenFactory = {
            let parameterStore = try ParameterStoreManager<AppleMusicSecret>(
                region: configuredRegion, logger: logger
            )
            let secret = try await parameterStore.getSecret(parameterName: secretName)
            return JWTTokenFactory(
                secretKey: secret.privateKey,
                keyId: secret.keyId,
                issuerId: secret.teamId
            )
        }()

        let (bucketRegion, tokenFactory) = try await (resolvedBucketRegion, resolvedTokenFactory)
        logger.info("Bucket \(bucket) is in region \(bucketRegion)")

        // Initialize auth provider with token cache
        let authProvider = AppleMusicAuthProvider(
            tokenFactory: tokenFactory
        )

        // Initialize HTTP client for Apple Music API
        let httpClient = MusicAPIClient()

        // Initialize S3 client adapter (uses the resolved bucket region)
        let s3ClientConfig = try await S3Client.S3ClientConfig(region: bucketRegion.rawValue)
        let s3Client = S3Manager(s3Client: S3Client(config: s3ClientConfig), region: bucketRegion)
        let s3Config = S3Config(s3Client: s3Client, bucket: bucket, keyPrefix: keyPrefix)
        let s3Writer = S3Writer(config: s3Config)

        // Read MAX_HISTORY_SIZE from environment
        let maxHistorySize: Int
        if let maxHistorySizeStr = Lambda.env("MAX_HISTORY_SIZE"), let parsed = Int(maxHistorySizeStr) {
            maxHistorySize = parsed
        } else {
            logger.warning("MAX_HISTORY_SIZE not set or invalid, using default 100")
            maxHistorySize = 100
        }

        // Assemble the collection pipeline with the production dependencies.
        self.collector = MetadataCollector(
            streamURL: streamURL,
            authProvider: authProvider,
            httpClient: httpClient,
            s3Writer: s3Writer,
            icecastReader: IcecastReader(),
            artworkDownloader: ArtworkDownloader(),
            historyManager: HistoryManager(config: s3Config, maxHistorySize: maxHistorySize)
        )

        logger.info("IcecastMetadataCollector initialized successfully")
    }

    func handle(_ event: EventBridgeEvent<CloudwatchDetails.Scheduled>, context: LambdaContext) async throws {
        try await collector.collect(logger: context.logger)
    }

    public static func main() async throws {
        let handler = try await IcecastMetadataCollector()
        let runtime = LambdaRuntime(lambdaHandler: handler)
        try await runtime.run()
    }
}
