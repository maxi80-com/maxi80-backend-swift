public import ArgumentParser
public import Maxi80Backend

extension Region: ExpressibleByArgument {
    public init?(argument: String) {
        guard !argument.isEmpty else { return nil }
        self.init(rawValue: argument)
    }
}
