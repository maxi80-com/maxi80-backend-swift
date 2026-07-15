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

    private let streamURL: String
    private let authProvider: AppleMusicAuthProvider
    private let httpClient: MusicAPIClient
    private let s3Writer: S3Writer
    private let icecastReader: IcecastReader
    private let artworkDownloader: ArtworkDownloader
    private let historyManager: HistoryManager

    init() async throws {
        let loggingConfig = LoggingConfiguration(logger: Logger(label: "IcecastMetadataCollector"))
        let logger = loggingConfig.makeRuntimeLogger()

        // Read required environment variables
        guard let streamURL = Lambda.env("STREAM_URL") else {
            throw CollectorError.missingEnvironmentVariable("STREAM_URL")
        }
        self.streamURL = streamURL

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
        self.authProvider = AppleMusicAuthProvider(
            tokenFactory: tokenFactory
        )

        // Initialize HTTP client for Apple Music API
        self.httpClient = MusicAPIClient()

        // Initialize S3 client adapter (uses the resolved bucket region)
        let s3ClientConfig = try await S3Client.S3ClientConfig(region: bucketRegion.rawValue)
        let s3Client = S3Manager(s3Client: S3Client(config: s3ClientConfig), region: bucketRegion)
        let s3Config = S3Config(s3Client: s3Client, bucket: bucket, keyPrefix: keyPrefix)
        self.s3Writer = S3Writer(config: s3Config)

        // Read MAX_HISTORY_SIZE from environment
        let maxHistorySize: Int
        if let maxHistorySizeStr = Lambda.env("MAX_HISTORY_SIZE"), let parsed = Int(maxHistorySizeStr) {
            maxHistorySize = parsed
        } else {
            logger.warning("MAX_HISTORY_SIZE not set or invalid, using default 100")
            maxHistorySize = 100
        }

        // Initialize HistoryManager
        self.historyManager = HistoryManager(
            config: s3Config,
            maxHistorySize: maxHistorySize
        )

        // Initialize IcecastReader and ArtworkDownloader
        self.icecastReader = IcecastReader()
        self.artworkDownloader = ArtworkDownloader()

        logger.info("IcecastMetadataCollector initialized successfully")
    }

    func handle(_ event: EventBridgeEvent<CloudwatchDetails.Scheduled>, context: LambdaContext) async throws {
        context.logger.info("Invocation started")

        // Step 1: Read Icecast stream metadata
        let rawMetadata: String
        do {
            rawMetadata = try await icecastReader.readMetadata(from: streamURL, logger: context.logger)
        } catch {
            context.logger.error("Failed to read Icecast stream: \(error)")
            throw error
        }
        context.logger.info("Raw metadata: \(rawMetadata)")

        // Step 2: Parse metadata into artist/title
        let trackMetadata = parseTrackMetadata(rawMetadata)
        guard let artist = trackMetadata.artist, let title = trackMetadata.title else {
            context.logger.warning("Empty metadata — both artist and title are nil, skipping")
            return
        }
        context.logger.info("Parsed: artist=\(artist), title=\(title)")

        // Step 2b: Check if this is the same track as the latest history entry — skip everything if so
        do {
            let history = try await historyManager.readHistory()
            if let latest = history.entries.max(by: { $0.timestamp < $1.timestamp }),
               latest.artist == artist, latest.title == title {
                context.logger.info("Same track as latest history entry (\(artist) - \(title)), skipping")
                return
            }
        } catch {
            context.logger.warning("Failed to read history for dedup check, continuing: \(error)")
        }

        // Step 2c: If artist is "maxi80" or "maxi 80" (case-insensitive), skip Apple Music search
        let normalizedArtist = artist.lowercased().trimmingCharacters(in: .whitespaces)
        if normalizedArtist == "maxi80" || normalizedArtist == "maxi 80" {
            context.logger.info("Artist is Maxi 80, skipping Apple Music search")
            await recordHistory(artist: artist, title: title, file: "nocover.jpg", logger: context.logger)
            return
        }

        // Step 3: Check S3 cache — if already collected, reuse the cached metadata (including
        // the dominant color) instead of calling Apple Music again.
        if let cached = try await s3Writer.readMetadata(artist: artist, title: title) {
            context.logger.info("Cache hit for \(artist)/\(title), skipping collection")

            // Backfill: legacy entries (collected before the color feature) have no color.
            // Do a one-time Apple Music search to fetch it and rewrite metadata.json so
            // future cache hits are free. A failed lookup records without color, never aborts.
            var color = cached.color
            if color == nil {
                do {
                    if let song = try await searchAppleMusic(artist: artist, title: title, logger: context.logger).song,
                       let backfilled = dominantColor(for: song) {
                        color = backfilled
                        let updated = CollectedMetadata(
                            rawMetadata: cached.rawMetadata, artist: cached.artist, title: cached.title,
                            collectedAt: cached.collectedAt, color: backfilled
                        )
                        try await s3Writer.writeMetadata(updated, artist: artist, title: title, logger: context.logger)
                        context.logger.info("Backfilled color \(backfilled) for cached \(artist) - \(title)")
                    }
                } catch {
                    context.logger.warning("Color backfill failed on cache hit for \(artist) - \(title), recording without color: \(error)")
                }
            }

            await recordHistory(artist: artist, title: title, file: "artwork.jpg", color: color, logger: context.logger)
            return
        }

        // Step 3b: Migrate legacy cache. Titles used to be stored with trailing parentheses
        // stripped; they are now stored in full. If no full-title object exists but a stripped-title
        // one does, copy its files to the full-title key, record history under the full title, and
        // delete the stripped-title originals (avoids re-downloading artwork, a duplicate history
        // entry, and paying for orphaned storage). A failed migration falls through to fresh
        // collection below.
        let stripped = searchTitle(title)
        if stripped != title {
            do {
                if let legacy = try await s3Writer.readMetadata(artist: artist, title: stripped) {
                    context.logger.info("Migrating stripped→full title cache: \(artist) - \(stripped) → \(title)")

                    for file in ["artwork.jpg", "search.json", "metadata.json"] {
                        do {
                            try await s3Writer.copyFile(file, artist: artist, fromTitle: stripped, toTitle: title, logger: context.logger)
                        } catch {
                            // artwork.jpg may be absent (nocover tracks); other files should exist.
                            context.logger.warning("Migration copy of \(file) failed for \(artist) - \(stripped): \(error)")
                        }
                    }

                    // Rewrite the copied metadata.json so its title matches the full-title key.
                    let migrated = CollectedMetadata(
                        rawMetadata: legacy.rawMetadata, artist: legacy.artist, title: title,
                        collectedAt: legacy.collectedAt, color: legacy.color
                    )
                    try await s3Writer.writeMetadata(migrated, artist: artist, title: title, logger: context.logger)

                    await recordHistory(artist: artist, title: title, file: "artwork.jpg", color: legacy.color, logger: context.logger)

                    for file in ["artwork.jpg", "search.json", "metadata.json"] {
                        do {
                            try await s3Writer.deleteFile(file, artist: artist, title: stripped, logger: context.logger)
                        } catch {
                            context.logger.warning("Migration delete of \(file) failed for \(artist) - \(stripped): \(error)")
                        }
                    }
                    return
                }
            } catch {
                context.logger.warning("Legacy-title migration failed for \(artist) - \(title), collecting fresh: \(error)")
            }
        }

        // Step 4: Search Apple Music
        let (searchData, bestMatch) = try await searchAppleMusic(artist: artist, title: title, logger: context.logger)

        // Step 5: Select best match
        guard let song = bestMatch else {
            context.logger.warning("No search results for \(artist) - \(title), skipping")

            // Record history entry even when Apple Music has no results
            await recordHistory(artist: artist, title: title, file: "nocover.jpg", logger: context.logger)

            return
        }
        context.logger.info("Selected song: \(song.attributes.name) by \(song.attributes.artistName ?? "Unknown")")

        // Step 6: Download artwork (if available). A failed download must not abort
        // collection — treat it as no artwork so the track is still recorded in history.
        let artworkData: Data?
        if let artwork = song.attributes.artwork {
            do {
                let data = try await artworkDownloader.download(artwork: artwork, logger: context.logger)
                artworkData = data
                context.logger.info("Downloaded artwork: \(data.count) bytes")
            } catch {
                artworkData = nil
                context.logger.warning("Artwork download failed for \(artist) - \(title), continuing without artwork: \(error)")
            }
        } else {
            artworkData = nil
            context.logger.warning("No artwork available for \(artist) - \(title)")
        }

        // Derive the dominant color from Apple's bgColor and cache it in metadata.json,
        // so future cache hits can reuse it without calling Apple Music again.
        let artworkColor = dominantColor(for: song)

        // Step 7: Upload all three files to S3
        let collectedMetadata = CollectedMetadata(
            rawMetadata: rawMetadata,
            artist: artist,
            title: title,
            collectedAt: Date.now.formatted(.iso8601),
            color: artworkColor
        )

        try await s3Writer.writeMetadata(collectedMetadata, artist: artist, title: title, logger: context.logger)
        try await s3Writer.writeSearchResults(searchData, artist: artist, title: title, logger: context.logger)
        if let artworkData {
            try await s3Writer.writeArtwork(artworkData, artist: artist, title: title, logger: context.logger)
        }

        // Record history entry for cache miss
        await recordHistory(artist: artist, title: title, file: artworkData != nil ? "artwork.jpg" : "nocover.jpg", color: artworkColor, logger: context.logger)

        context.logger.info("Successfully collected metadata for \(artist) - \(title)")
    }

    private func recordHistory(artist: String, title: String, file: String, color: String? = nil, logger: Logger) async {
        let artworkKey = buildS3Key(prefix: s3Writer.config.keyPrefix, artist: artist, title: title, file: file)
        let timestamp = Date.now.formatted(.iso8601)
        await historyManager.recordEntry(artist: artist, title: title, artworkKey: artworkKey, timestamp: timestamp, color: color, logger: logger)
    }

    /// Searches Apple Music and returns the raw response bytes plus the best-matching song (if any).
    private func searchAppleMusic(artist: String, title: String, logger: Logger) async throws -> (data: Data, song: Song?) {
        let searchFields = AppleMusicSearchType.items(searchTypes: [.songs])
        // Strip trailing parentheses (remix/edit annotations) from the title for the search term
        // only — the stored/displayed title keeps them. See searchTitle(_:).
        let searchTerms = AppleMusicSearchType.term(search: "\(artist) \(searchTitle(title))")

        let (searchData, _) = try await httpClient.apiCall(
            url: AppleMusicEndpoint.search.url(args: [searchFields, searchTerms]),
            method: .GET,
            body: nil,
            headers: try await authProvider.authorizationHeader(logger: logger),
            timeout: 10,
            logger: logger
        )

        let searchResponse = try JSONDecoder().decode(AppleMusicSearchResponse.self, from: searchData)
        return (searchData, selectBestMatch(searchResponse))
    }

    /// Derives the dominant artwork color ("#RRGGBB") from Apple's bgColor, or nil when unavailable.
    private func dominantColor(for song: Song) -> String? {
        song.attributes.artwork.flatMap { DominantColor().normalizedHex(fromAppleBgColor: $0.bgColor) }
    }

    public static func main() async throws {
        let handler = try await IcecastMetadataCollector()
        let runtime = LambdaRuntime(lambdaHandler: handler)
        try await runtime.run()
    }
}
