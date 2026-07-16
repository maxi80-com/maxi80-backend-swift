public protocol PathMatchable: RawRepresentable, CaseIterable where RawValue == String {
    static func from(path: String) -> Self?
}

extension PathMatchable {
    public static func from(path: String) -> Self? {
        allCases.first { $0.rawValue == path }
    }
}
