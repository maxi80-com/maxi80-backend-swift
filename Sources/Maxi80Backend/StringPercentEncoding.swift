extension StringProtocol {
    /// Stdlib-only percent-encoding equivalent of
    /// `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)`.
    ///
    /// Avoids importing full `Foundation` (only `FoundationEssentials` is used on Linux
    /// to keep the Lambda binary small; `CharacterSet` is not part of FoundationEssentials).
    ///
    /// Passes through the RFC 3986 unreserved set (`A-Z a-z 0-9 - . _ ~`) plus the
    /// sub-delimiters and separators that `.urlPathAllowed` permits in a path, and
    /// percent-encodes everything else as UTF-8 bytes.
    public func addingPathPercentEncoding() -> String {
        // Characters allowed unencoded in a URL path component by `.urlPathAllowed`.
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/!$&'()*+,;=:@")
        let hexDigits = Array("0123456789ABCDEF")
        var result = ""
        for byte in utf8 {
            let scalar = Unicode.Scalar(byte)
            if allowed.contains(Character(scalar)) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("%")
                result.append(hexDigits[Int(byte >> 4)])
                result.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return result
    }
}
