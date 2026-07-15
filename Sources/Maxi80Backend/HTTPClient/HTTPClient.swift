import AsyncHTTPClient
public import Logging
import NIOCore
public import NIOHTTP1

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// Protocol for dependency injection and testing
public protocol HTTPClientProtocol {
    func apiCall(
        url: URL,
        method: NIOHTTP1.HTTPMethod,
        body: Data?,
        headers: [String: String],
        timeout: Int64,
        logger: Logger
    ) async throws -> (Data, HTTPResponseStatus)
}

// provide common code for all network clients
public struct MusicAPIClient: HTTPClientProtocol {

    public init() {}

    private let standardHeaders: [String: String] = [
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-Requested-With": "XMLHttpRequest",
        "User-Agent": "maxi80/1.0",
    ]

    // generic API CALL method
    public func apiCall(
        url: URL,
        method: NIOHTTP1.HTTPMethod = .GET,
        body: Data? = nil,
        headers: [String: String] = [:],
        timeout: Int64 = 10,
        logger: Logger
    ) async throws -> (Data, HTTPResponseStatus) {

        var logger = logger
        logger[metadataKey: "Component"] = "MusicAPIClient"

        // let's add provided headers to our request (keeping new value in case of conflicts)
        var requestHeaders = standardHeaders

        // add the headers our caller wants in this request
        requestHeaders.merge(headers, uniquingKeysWith: { (_, new) in new })

        // and build the request
        let request = self.request(
            for: url,
            method: method,
            withBody: body,
            withHeaders: requestHeaders
        )

        await logger.request(request)

        // send request with that session
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(timeout))
        guard response.status == .ok else {
            logger.error("\(response.status.reasonPhrase)")
            logger.trace("URLResponse : \(response.status)")
            throw HTTPClientError.badServerResponse(status: response.status)
        }

        let maxSize = Int(response.headers.first(name: "content-length") ?? "") ?? (10 * 1024 * 1024)
        guard let bytes = try? await response.body.collect(upTo: max(maxSize, 10 * 1024 * 1024)) else {
            logger.debug("No readable bytes in the response")
            throw HTTPClientError.zeroByteResource
        }

        let data = Data(bytes.readableBytesView)
        logger.response(response, data: data, error: nil)

        return (data, response.status)
    }

    // prepare an HTTPClientRequest for a given url, method, body, and headers
    // https://softwareengineering.stackexchange.com/questions/100959/how-do-you-unit-test-private-methods
    // by OOP design it should be private.  Make it internal (default) for testing
    internal func request(
        for url: URL,
        method: NIOHTTP1.HTTPMethod = .GET,
        withBody body: Data? = nil,
        withHeaders headers: [String: String]? = nil
    ) -> HTTPClientRequest {

        // create the request
        var request = HTTPClientRequest(url: url.absoluteString)

        // add HTTP verb
        request.method = method

        // add body
        if let body {
            request.body = HTTPClientRequest.Body.bytes(ByteBuffer(bytes: body))
        }

        // add headers
        if let headers {
            for (key, value) in headers {
                request.headers.add(name: key, value: value)
            }
        }

        return request
    }
}

public enum HTTPClientError: Error, CustomStringConvertible {
    case badServerResponse(status: HTTPResponseStatus)
    case zeroByteResource

    public var description: String {
        switch self {
        case .badServerResponse(let status): return "Bad server response: \(status.code) \(status.reasonPhrase)"
        case .zeroByteResource: return "Response body contained zero readable bytes"
        }
    }
}
