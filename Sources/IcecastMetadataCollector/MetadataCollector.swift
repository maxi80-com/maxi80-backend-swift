import Logging
import Maxi80Backend
import NIOHTTP1

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The Icecast metadata collection pipeline, extracted from the Lambda handler so its business
/// logic can be unit-tested with injected fakes. All external effects (stream read, Apple Music
/// search, artwork download, S3 I/O, history) arrive through injected dependencies.
struct MetadataCollector {
    let streamURL: String
    let authProvider: any AuthorizationProvider
    let httpClient: any HTTPClientProtocol
    let s3Writer: S3Writer
    let icecastReader: any IcecastReading
    let artworkDownloader: any ArtworkDownloading
    let historyManager: HistoryManager

    init(
        streamURL: String,
        authProvider: any AuthorizationProvider,
        httpClient: any HTTPClientProtocol,
        s3Writer: S3Writer,
        icecastReader: any IcecastReading,
        artworkDownloader: any ArtworkDownloading,
        historyManager: HistoryManager
    ) {
        self.streamURL = streamURL
        self.authProvider = authProvider
        self.httpClient = httpClient
        self.s3Writer = s3Writer
        self.icecastReader = icecastReader
        self.artworkDownloader = artworkDownloader
        self.historyManager = historyManager
    }

    /// Runs one collection cycle: read the stream, parse, dedup, and either reuse/migrate the cache
    /// or collect fresh from Apple Music, recording a history entry in every non-skip branch.
    func collect(logger: Logger) async throws {
        logger.info("Invocation started")

        // Step 1: Read Icecast stream metadata
        let rawMetadata: String
        do {
            rawMetadata = try await icecastReader.readMetadata(from: streamURL, logger: logger)
        } catch {
            logger.error("Failed to read Icecast stream: \(error)")
            throw error
        }
        logger.info("Raw metadata: \(rawMetadata)")

        // Step 2: Parse metadata into artist/title
        let trackMetadata = parseTrackMetadata(rawMetadata)
        guard let artist = trackMetadata.artist, let title = trackMetadata.title else {
            logger.warning("Empty metadata — both artist and title are nil, skipping")
            return
        }
        logger.info("Parsed: artist=\(artist), title=\(title)")

        // Step 2b: Check if this is the same track as the latest history entry — skip everything if so
        do {
            let history = try await historyManager.readHistory()
            if let latest = history.entries.max(by: { $0.timestamp < $1.timestamp }),
                latest.artist == artist, latest.title == title
            {
                logger.info("Same track as latest history entry (\(artist) - \(title)), skipping")
                return
            }
        } catch {
            logger.warning("Failed to read history for dedup check, continuing: \(error)")
        }

        // Step 2c: If artist is "maxi80" or "maxi 80" (case-insensitive), skip Apple Music search
        let normalizedArtist = artist.lowercased().trimmingWhitespace()
        if normalizedArtist == "maxi80" || normalizedArtist == "maxi 80" {
            logger.info("Artist is Maxi 80, skipping Apple Music search")
            await recordHistory(artist: artist, title: title, file: "nocover.jpg", logger: logger)
            return
        }

        // Step 3: Check S3 cache — if already collected, reuse the cached metadata (including
        // the dominant color) instead of calling Apple Music again.
        if let cached = try await s3Writer.readMetadata(artist: artist, title: title) {
            logger.info("Cache hit for \(artist)/\(title), skipping collection")

            // Backfill: legacy entries (collected before the color feature) have no color.
            // Do a one-time Apple Music search to fetch it and rewrite metadata.json so
            // future cache hits are free. A failed lookup records without color, never aborts.
            var color = cached.color
            if color == nil {
                do {
                    if let song = try await searchAppleMusic(artist: artist, title: title, logger: logger).song,
                        let backfilled = dominantColor(for: song)
                    {
                        color = backfilled
                        let updated = CollectedMetadata(
                            rawMetadata: cached.rawMetadata,
                            artist: cached.artist,
                            title: cached.title,
                            collectedAt: cached.collectedAt,
                            color: backfilled
                        )
                        try await s3Writer.writeMetadata(updated, artist: artist, title: title, logger: logger)
                        logger.info("Backfilled color \(backfilled) for cached \(artist) - \(title)")
                    }
                } catch {
                    logger.warning(
                        "Color backfill failed on cache hit for \(artist) - \(title), recording without color: \(error)"
                    )
                }
            }

            await recordHistory(artist: artist, title: title, file: "artwork.jpg", color: color, logger: logger)
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
                    logger.info("Migrating stripped→full title cache: \(artist) - \(stripped) → \(title)")

                    for file in ["artwork.jpg", "search.json", "metadata.json"] {
                        do {
                            try await s3Writer.copyFile(
                                file,
                                artist: artist,
                                fromTitle: stripped,
                                toTitle: title,
                                logger: logger
                            )
                        } catch {
                            // artwork.jpg may be absent (nocover tracks); other files should exist.
                            logger.warning("Migration copy of \(file) failed for \(artist) - \(stripped): \(error)")
                        }
                    }

                    // Rewrite the copied metadata.json so its title matches the full-title key.
                    let migrated = CollectedMetadata(
                        rawMetadata: legacy.rawMetadata,
                        artist: legacy.artist,
                        title: title,
                        collectedAt: legacy.collectedAt,
                        color: legacy.color
                    )
                    try await s3Writer.writeMetadata(migrated, artist: artist, title: title, logger: logger)

                    await recordHistory(
                        artist: artist,
                        title: title,
                        file: "artwork.jpg",
                        color: legacy.color,
                        logger: logger
                    )

                    for file in ["artwork.jpg", "search.json", "metadata.json"] {
                        do {
                            try await s3Writer.deleteFile(file, artist: artist, title: stripped, logger: logger)
                        } catch {
                            logger.warning("Migration delete of \(file) failed for \(artist) - \(stripped): \(error)")
                        }
                    }
                    return
                }
            } catch {
                logger.warning("Legacy-title migration failed for \(artist) - \(title), collecting fresh: \(error)")
            }
        }

        // Step 4: Search Apple Music
        let (searchData, bestMatch) = try await searchAppleMusic(artist: artist, title: title, logger: logger)

        // Step 5: Select best match
        guard let song = bestMatch else {
            logger.warning("No search results for \(artist) - \(title), skipping")

            // Record history entry even when Apple Music has no results
            await recordHistory(artist: artist, title: title, file: "nocover.jpg", logger: logger)

            return
        }
        logger.info("Selected song: \(song.attributes.name) by \(song.attributes.artistName ?? "Unknown")")

        // Step 6: Download artwork (if available). A failed download must not abort
        // collection — treat it as no artwork so the track is still recorded in history.
        let artworkData: Data?
        if let artwork = song.attributes.artwork {
            do {
                let data = try await artworkDownloader.download(artwork: artwork, logger: logger)
                artworkData = data
                logger.info("Downloaded artwork: \(data.count) bytes")
            } catch {
                artworkData = nil
                logger.warning("Artwork download failed for \(artist) - \(title), continuing without artwork: \(error)")
            }
        } else {
            artworkData = nil
            logger.warning("No artwork available for \(artist) - \(title)")
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

        try await s3Writer.writeMetadata(collectedMetadata, artist: artist, title: title, logger: logger)
        try await s3Writer.writeSearchResults(searchData, artist: artist, title: title, logger: logger)
        if let artworkData {
            try await s3Writer.writeArtwork(artworkData, artist: artist, title: title, logger: logger)
        }

        // Record history entry for cache miss
        await recordHistory(
            artist: artist,
            title: title,
            file: artworkData != nil ? "artwork.jpg" : "nocover.jpg",
            color: artworkColor,
            logger: logger
        )

        logger.info("Successfully collected metadata for \(artist) - \(title)")
    }

    private func recordHistory(artist: String, title: String, file: String, color: String? = nil, logger: Logger) async
    {
        let artworkKey = buildS3Key(prefix: s3Writer.config.keyPrefix, artist: artist, title: title, file: file)
        let timestamp = Date.now.formatted(.iso8601)
        await historyManager.recordEntry(
            artist: artist,
            title: title,
            artworkKey: artworkKey,
            timestamp: timestamp,
            color: color,
            logger: logger
        )
    }

    /// Searches Apple Music and returns the raw response bytes plus the best-matching song (if any).
    private func searchAppleMusic(
        artist: String,
        title: String,
        logger: Logger
    ) async throws -> (data: Data, song: Song?) {
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
}
