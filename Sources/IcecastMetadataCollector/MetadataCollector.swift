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

    /// What to write to history for this invocation: the artwork file name (`artwork.jpg` or
    /// `nocover.jpg`) and the optional palette. `nil` from `enrich` means "dedup skip —
    /// record nothing".
    private struct HistoryOutcome {
        let file: String
        let colors: ArtworkColors?
    }

    /// Runs one collection cycle: read the stream, parse, then enrich (dedup / cache / migrate /
    /// search / download) and record history.
    ///
    /// History is recorded in exactly ONE place — here — for every track that is not a dedup skip.
    /// If enrichment throws for any reason (S3 cache read, Apple Music search, artwork download, S3
    /// writes), the track is still recorded with a `nocover.jpg` placeholder rather than being lost.
    /// The only case with no history entry is when we never learn the track: a stream-read failure
    /// or empty metadata.
    func collect(logger: Logger) async throws {
        logger.info("Invocation started")

        // Step 1: Read Icecast stream metadata. Without this we have no track to record, so a
        // failure here propagates (and the invocation is retried) rather than recording a placeholder.
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

        // Enrich and decide what to record. Any thrown error degrades to a no-cover entry so the
        // track always lands in history — this is the fix for tracks vanishing when a cache read /
        // search / write failed upstream of the old per-branch recordHistory calls.
        let outcome: HistoryOutcome?
        do {
            outcome = try await enrich(artist: artist, title: title, rawMetadata: rawMetadata, logger: logger)
        } catch {
            logger.error(
                "Enrichment failed for \(artist) - \(title), recording without cover: \(type(of: error)): \(error)"
            )
            outcome = HistoryOutcome(file: "nocover.jpg", colors: nil)
        }

        guard let outcome else {
            logger.debug("Path: dedup skip — no history entry recorded for \(artist) - \(title)")
            return
        }

        await recordHistory(artist: artist, title: title, file: outcome.file, colors: outcome.colors, logger: logger)
        logger.info("Successfully collected metadata for \(artist) - \(title) [\(outcome.file)]")
    }

    /// The enrichment pipeline: dedup check, Maxi80 skip, S3 cache hit, legacy-title migration, or
    /// fresh Apple Music collection. Returns the `HistoryOutcome` to record, or `nil` for a dedup
    /// skip. Throwing propagates to `collect`, which records a no-cover fallback entry.
    private func enrich(
        artist: String,
        title: String,
        rawMetadata: String,
        logger: Logger
    ) async throws -> HistoryOutcome? {
        // Step 2b: Check if this is the same track as the latest history entry — skip everything if so.
        // A failure to read history here is non-fatal: we log and fall through to (re)collect.
        do {
            logger.debug("Path: reading history for dedup check")
            let history = try await historyManager.readHistory()
            logger.debug("Path: read history — \(history.entries.count) entries")
            if let latest = history.entries.max(by: { $0.timestamp < $1.timestamp }),
                latest.artist == artist, latest.title == title
            {
                logger.info("Same track as latest history entry (\(artist) - \(title)), skipping")
                return nil
            }
        } catch {
            logger.warning("Failed to read history for dedup check, continuing: \(error)")
        }

        // Step 2c: If artist is "maxi80" or "maxi 80" (case-insensitive), skip Apple Music search
        let normalizedArtist = artist.lowercased().trimmingWhitespace()
        if normalizedArtist == "maxi80" || normalizedArtist == "maxi 80" {
            logger.debug("Path: Maxi 80 filler → recording nocover, skipping Apple Music search")
            return HistoryOutcome(file: "nocover.jpg", colors: nil)
        }

        // Step 3: Check S3 cache — if already collected, reuse the cached palette instead of
        // calling Apple Music again. (The one-off scripts/backfill-colors.sh converts any objects
        // collected before the palette schema, so there is no lazy per-request backfill here.)
        logger.debug("Path: checking S3 cache for \(artist)/\(title)")
        if let cached = try await s3Writer.readMetadata(artist: artist, title: title) {
            logger.info("Cache hit for \(artist)/\(title), skipping collection")
            logger.debug("Path: cache hit → recording artwork")
            return HistoryOutcome(file: "artwork.jpg", colors: cached.colors)
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
                    logger.debug("Path: migration entered")

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
                        colors: legacy.colors
                    )
                    try await s3Writer.writeMetadata(migrated, artist: artist, title: title, logger: logger)
                    logger.debug("Path: migration rewrote metadata.json under full title")

                    for file in ["artwork.jpg", "search.json", "metadata.json"] {
                        do {
                            try await s3Writer.deleteFile(file, artist: artist, title: stripped, logger: logger)
                        } catch {
                            logger.warning("Migration delete of \(file) failed for \(artist) - \(stripped): \(error)")
                        }
                    }

                    logger.debug("Path: migration complete → recording artwork")
                    return HistoryOutcome(file: "artwork.jpg", colors: legacy.colors)
                }
            } catch {
                logger.warning("Legacy-title migration failed for \(artist) - \(title), collecting fresh: \(error)")
            }
        }

        // Step 4: Search Apple Music
        logger.debug("Path: cache miss → searching Apple Music for \(artist) - \(searchTitle(title))")
        let (searchData, bestMatch) = try await searchAppleMusic(artist: artist, title: title, logger: logger)

        // Step 5: Select best match
        guard let song = bestMatch else {
            logger.warning("No search results for \(artist) - \(title), skipping")
            logger.debug("Path: no search results → recording nocover")
            return HistoryOutcome(file: "nocover.jpg", colors: nil)
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

        // Capture Apple's full artwork palette and cache it in metadata.json so future cache hits
        // reuse it without calling Apple Music again. The client picks the display color.
        let colors = artworkColors(for: song)

        // Step 7: Upload all three files to S3
        let collectedMetadata = CollectedMetadata(
            rawMetadata: rawMetadata,
            artist: artist,
            title: title,
            collectedAt: Date.now.formatted(.iso8601),
            colors: colors
        )

        try await s3Writer.writeMetadata(collectedMetadata, artist: artist, title: title, logger: logger)
        try await s3Writer.writeSearchResults(searchData, artist: artist, title: title, logger: logger)
        if let artworkData {
            try await s3Writer.writeArtwork(artworkData, artist: artist, title: title, logger: logger)
        }

        let file = artworkData != nil ? "artwork.jpg" : "nocover.jpg"
        logger.debug("Path: fresh collection complete → recording \(file)")
        return HistoryOutcome(file: file, colors: colors)
    }

    private func recordHistory(
        artist: String,
        title: String,
        file: String,
        colors: ArtworkColors? = nil,
        logger: Logger
    )
        async
    {
        let artworkKey = buildS3Key(prefix: s3Writer.config.keyPrefix, artist: artist, title: title, file: file)
        let timestamp = Date.now.formatted(.iso8601)
        logger.debug("recordHistory: artist=\(artist), title=\(title), file=\(file), colors=\(colors != nil)")
        await historyManager.recordEntry(
            artist: artist,
            title: title,
            artworkKey: artworkKey,
            timestamp: timestamp,
            colors: colors,
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

    /// The Apple Music artwork palette to store, or nil when no artwork/valid colors are available.
    private func artworkColors(for song: Song) -> ArtworkColors? {
        song.attributes.artwork.flatMap { ArtworkColors(artwork: $0) }
    }
}
