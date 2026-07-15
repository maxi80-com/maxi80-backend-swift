#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// https://developer.apple.com/documentation/applemusicapi

public enum AppleMusicSearchType: String, Sendable {
    case artists
    case songs
    case albums

    public static func items(searchTypes: [AppleMusicSearchType]) -> URLQueryItem {
        URLQueryItem(
            name: "types",
            value: String(searchTypes.map { $0.rawValue }.joined(separator: ","))
        )
    }
    public static func term(search: String) -> URLQueryItem {
        URLQueryItem(name: "term", value: search)
    }
}

public enum AppleMusicEndpoint: String, CaseIterable, Sendable, PathMatchable {

    #if DEBUG
    case test = "/test"
    #endif
    case search = "/catalog/fr/search"

    private func baseURI() -> URL {
        URL(string: "https://api.music.apple.com/v1")!
    }

    public func url(args: [URLQueryItem] = []) -> URL {
        var result = baseURI().appendingPathComponent(self.rawValue)
        if !args.isEmpty {
            result.append(queryItems: args)
        }
        return result
    }
}
