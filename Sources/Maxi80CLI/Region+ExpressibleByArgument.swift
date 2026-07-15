public import ArgumentParser
public import SotoCore

extension Region: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        guard !argument.isEmpty else { return nil }
        self.init(rawValue: argument)
    }
}
