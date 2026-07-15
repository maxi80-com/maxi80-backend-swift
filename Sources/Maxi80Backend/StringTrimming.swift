extension StringProtocol {
    /// Stdlib-only equivalent of `trimmingCharacters(in: .whitespacesAndNewlines)`.
    ///
    /// Avoids importing full `Foundation` (only `FoundationEssentials` is used on Linux
    /// to keep the Lambda binary small). `Character.isWhitespace` matches spaces, tabs,
    /// and newlines.
    public func trimmingWhitespace() -> String {
        guard let start = firstIndex(where: { !$0.isWhitespace }),
              let end = lastIndex(where: { !$0.isWhitespace })
        else {
            return ""
        }
        return String(self[start...end])
    }
}
