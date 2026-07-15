import Foundation
import Logging
import Maxi80Backend
import NIOHTTP1

/// Mock HTTP client for testing
actor MockHTTPClient: HTTPClientProtocol {

    struct CallRecord: Sendable {
        let url: URL
        let method: NIOHTTP1.HTTPMethod
        let body: Data?
        let headers: [String: String]
        let timeout: Int64
    }

    private var callRecords: [CallRecord] = []
    private var responseData: [Data] = []
    private var responseStatuses: [HTTPResponseStatus] = []
    private var errors: [any Error] = []
    private var currentIndex = 0

    init() {}

    func apiCall(
        url: URL,
        method: NIOHTTP1.HTTPMethod = .GET,
        body: Data? = nil,
        headers: [String: String] = [:],
        timeout: Int64 = 10,
        logger: Logger = Logger(label: "mock")
    ) async throws -> (Data, HTTPResponseStatus) {

        // Record the call
        let record = CallRecord(
            url: url,
            method: method,
            body: body,
            headers: headers,
            timeout: timeout
        )
        callRecords.append(record)

        // Check if we should throw an error
        if currentIndex < errors.count {
            let error = errors[currentIndex]
            currentIndex += 1
            throw error
        }

        // Return pre-configured response
        guard currentIndex < responseData.count else {
            throw HTTPClientError.zeroByteResource
        }

        let data = responseData[currentIndex]
        let status = currentIndex < responseStatuses.count ? responseStatuses[currentIndex] : .ok
        currentIndex += 1

        return (data, status)
    }

    // MARK: - Test helpers

    func setResponse(data: Data, status: HTTPResponseStatus = .ok) {
        responseData.append(data)
        responseStatuses.append(status)
    }

    func setError(_ error: any Error) {
        errors.append(error)
    }

    func getCallRecords() -> [CallRecord] {
        callRecords
    }

    func reset() {
        callRecords.removeAll()
        responseData.removeAll()
        responseStatuses.removeAll()
        errors.removeAll()
        currentIndex = 0
    }
}
