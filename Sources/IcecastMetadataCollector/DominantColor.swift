#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct DominantColor {

    /// Normalizes Apple Music's `bgColor` into the client contract format.
    /// Apple returns 6 hex digits without a leading `#` and of unspecified case (e.g. "3d2a1c").
    /// Returns "#RRGGBB" uppercase, or nil if the input is not exactly 6 hex digits.
    func normalizedHex(fromAppleBgColor raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + value.uppercased()
    }
}
