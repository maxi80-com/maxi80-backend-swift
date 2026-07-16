public import Logging
public import Routing

/// Wires the Maxi80 HTTP endpoints onto a lambda-kit `HTTPRouter`.
///
/// Registration happens once at construction; `handle` is safe to call across
/// invocations. Owning the route table in one type keeps the wiring testable
/// independently of the Lambda entry point.
public struct Maxi80Router: Sendable {
    private let router: HTTPRouter

    public init(
        station: StationAction,
        artwork: ArtworkAction,
        history: HistoryAction
    ) {
        let builder = HTTPRouterBuilder()
        builder.get("/station") { request, logger in try await station.handle(request, logger) }
        builder.get("/artwork") { request, logger in try await artwork.handle(request, logger) }
        builder.get("/history") { request, logger in try await history.handle(request, logger) }
        self.router = builder.build()
    }

    public func handle(_ request: HTTPRequest, logger: Logger) async -> Response {
        await router.handle(request, logger: logger)
    }
}
