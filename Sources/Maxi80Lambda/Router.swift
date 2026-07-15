public import AWSLambdaEvents
public import HTTPTypes
public import Logging
import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Router handles request routing and returns the appropriate action
public struct Router {
    private let actions: [any Action]

    public init(actions: [any Action]) {
        self.actions = actions
    }

    /// Routes an incoming HTTP API Gateway V2 request to the appropriate action
    public func route(_ event: APIGatewayV2Request, logger: Logger) -> Result<any Action, RouterError> {
        let method = event.context.http.method
        let path = event.rawPath

        logger.trace("Routing request - Method: \(method.rawValue), Path: \(path)")

        // Verify path exists
        guard let endpoint = Maxi80Endpoint.from(path: path) else {
            return .failure(.pathNotFound(path: path))
        }

        // Find action matching both endpoint and method
        guard let action = actions.first(where: { $0.endpoint == endpoint && $0.method == method }) else {
            return .failure(.methodNotAllowed(path: path, method: method.rawValue))
        }

        return .success(action)
    }
}

/// Router-specific errors
public enum RouterError: Error, CustomStringConvertible {
    case pathNotFound(path: String)
    case methodNotAllowed(path: String, method: String)

    public var description: String {
        switch self {
        case .pathNotFound(let path):
            return "Path not found: \(path)"
        case .methodNotAllowed(let path, let method):
            return "Method \(method) not allowed for path: \(path)"
        }
    }

    public var statusCode: HTTPResponse.Status {
        switch self {
        case .pathNotFound:
            return .notFound
        case .methodNotAllowed:
            return .methodNotAllowed
        }
    }
}
