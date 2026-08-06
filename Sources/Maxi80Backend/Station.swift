public struct Station: Codable, Sendable {
    public let name: String
    public let streamUrl: String
    public let image: String
    public let shortDesc: String
    public let longDesc: String
    public let websiteUrl: String
    public let donationUrl: String
    public let defaultCoverUrl: String

    /// Runtime feature toggles for the client, `lower_snake_case` name → enabled.
    ///
    /// Optional on purpose: `nil` means the `features` key is **omitted** from the encoded JSON (the
    /// synthesized encoder uses `encodeIfPresent`) rather than emitted as `{}` or `null`. App
    /// versions released before feature flags existed decode `Station` without this field, so the
    /// absent-key form is the backward-compatible one and must stay the default. Clients ignore flag
    /// names they do not know, so new flags can ship here ahead of the client that reads them.
    public let features: [String: Bool]?

    public init(
        name: String,
        streamUrl: String,
        image: String,
        shortDesc: String,
        longDesc: String,
        websiteUrl: String,
        donationUrl: String,
        defaultCoverUrl: String,
        features: [String: Bool]? = nil
    ) {
        self.name = name
        self.streamUrl = streamUrl
        self.image = image
        self.shortDesc = shortDesc
        self.longDesc = longDesc
        self.websiteUrl = websiteUrl
        self.donationUrl = donationUrl
        self.defaultCoverUrl = defaultCoverUrl
        // An empty dictionary would serialize as `"features": {}` — no information, and a needless
        // payload change for older clients. Collapse it to the absent form.
        let features = features.flatMap { $0.isEmpty ? nil : $0 }
        self.features = features
    }

    public static let `default` = Station(
        name: "Maxi 80",
        streamUrl: "https://audio1.maxi80.com",
        image: "maxi80_nocover-b.png",
        shortDesc: "La radio de toute une génération",
        longDesc: "Le meilleur de la musique des années 80",
        websiteUrl: "https://maxi80.com",
        donationUrl: "https://www.maxi80.com/paypal.htm",
        defaultCoverUrl: "file://maxi80_nocover-b.png"
    )

    /// Returns a copy carrying the given runtime flags. With no flags configured the payload is
    /// unchanged — `features` key omitted entirely, which is what pre-flags app versions expect.
    public func withFeatures(_ flags: FeatureFlags) -> Station {
        Station(
            name: name,
            streamUrl: streamUrl,
            image: image,
            shortDesc: shortDesc,
            longDesc: longDesc,
            websiteUrl: websiteUrl,
            donationUrl: donationUrl,
            defaultCoverUrl: defaultCoverUrl,
            features: flags.values
        )
    }
}
