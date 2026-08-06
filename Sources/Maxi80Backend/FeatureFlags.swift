/// Runtime feature toggles served to the mobile apps inside the `/station` response.
///
/// Flags let the client enable or disable a feature without an app-store release. They are plain
/// configuration — not secrets — so they are read from the `FEATURE_FLAGS` environment variable of
/// `Maxi80Lambda` (declared in `template.yaml`), the same mechanism the function already uses for
/// `S3_BUCKET` / `KEY_PREFIX` / `URL_EXPIRATION`. Parameter Store stays reserved for SecureString
/// secrets, and an operator can flip a flag with a single `update-function-configuration` call
/// without rebuilding or redeploying.
///
/// Wire format of the variable is a comma-separated list of `name=bool` pairs:
///
/// ```
/// FEATURE_FLAGS="anniversary_cover=true, sleep_timer=1"
/// ```
///
/// Flag names are `lower_snake_case` and are passed through verbatim: the backend does not keep a
/// list of known flags, so a new flag can be enabled before or after the client that reads it
/// ships. A malformed entry is dropped instead of failing the endpoint — a typo in the environment
/// variable must never take `/station` down — and is surfaced through ``malformedEntries`` so the
/// caller can log it.
public struct FeatureFlags: Sendable, Equatable {

    /// Name of the environment variable holding the flag configuration.
    public static let environmentKey = "FEATURE_FLAGS"

    /// No flags configured. Encodes to a `/station` payload with no `features` key at all.
    public static let none = FeatureFlags()

    /// Parsed flags, keyed by flag name. A duplicated name keeps the last occurrence.
    public let values: [String: Bool]

    /// Entries the parser could not understand, kept verbatim for logging.
    public let malformedEntries: [String]

    public var isEmpty: Bool { values.isEmpty }

    public init(values: [String: Bool] = [:], malformedEntries: [String] = []) {
        self.values = values
        self.malformedEntries = malformedEntries
    }

    /// Parses the `FEATURE_FLAGS` environment value.
    ///
    /// A `nil`, empty, or whitespace-only value yields ``none``, which keeps `/station` byte-for-byte
    /// identical to the pre-feature-flags payload.
    public init(environmentValue: String?) {
        guard let raw = environmentValue?.trimmingWhitespace(), !raw.isEmpty else {
            self.init()
            return
        }

        var parsed: [String: Bool] = [:]
        var malformed: [String] = []

        for entry in raw.split(separator: ",") {
            let entry = entry.trimmingWhitespace()
            // Tolerate a trailing comma or double separator.
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                malformed.append(entry)
                continue
            }

            let name = parts[0].trimmingWhitespace()
            guard !name.isEmpty, let value = parts[1].configurationBoolean else {
                malformed.append(entry)
                continue
            }

            parsed[name] = value
        }

        self.init(values: parsed, malformedEntries: malformed)
    }
}

extension StringProtocol {
    /// Parses a configuration-style boolean: `true`/`false` or `1`/`0`, case-insensitive and
    /// surrounded by optional whitespace. Returns `nil` for anything else.
    fileprivate var configurationBoolean: Bool? {
        switch trimmingWhitespace().lowercased() {
        case "true", "1": true
        case "false", "0": false
        default: nil
        }
    }
}
