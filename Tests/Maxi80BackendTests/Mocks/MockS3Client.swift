@testable import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Mock S3 client for testing
public actor MockS3Client: S3ManagerProtocol {

    private var existsResults: [Bool] = []
    private var presignedURLs: [String] = []
    private var errors: [Error] = []
    private var callRecords: [(bucket: String, key: String)] = []
    private var presignExpirations: [TimeInterval] = []
    private var putRecords: [(data: Data, bucket: String, key: String, contentType: String)] = []
    private var getObjectResults: [Data?] = []
    /// Key-addressed responses. When a key is present here it takes precedence over the sequential
    /// `getObjectResults` queue — useful for tests that issue getObject in a hard-to-predict order.
    private var getObjectByKey: [String: Data] = [:]
    private var useKeyedGetObject = false
    private var copyRecords: [(bucket: String, fromKey: String, toKey: String)] = []
    private var deleteRecords: [(bucket: String, key: String)] = []
    private var existsIndex = 0
    private var presignIndex = 0
    private var getObjectIndex = 0

    public init() {}

    public func objectExists(bucket: String, key: String) async throws -> Bool {
        callRecords.append((bucket: bucket, key: key))

        if existsIndex < errors.count {
            let error = errors[existsIndex]
            existsIndex += 1
            throw error
        }

        guard existsIndex < existsResults.count else {
            return false
        }

        let result = existsResults[existsIndex]
        existsIndex += 1
        return result
    }

    public func presignedGetURL(bucket: String, key: String, expiration: TimeInterval) async throws -> URL {
        presignExpirations.append(expiration)

        guard presignIndex < presignedURLs.count else {
            return URL(string: "https://s3.example.com/\(key)")!
        }

        let result = presignedURLs[presignIndex]
        presignIndex += 1
        return URL(string: result)!
    }

    public func putObject(data: Data, bucket: String, key: String, contentType: String) async throws {
        putRecords.append((data: data, bucket: bucket, key: key, contentType: contentType))
        if useKeyedGetObject {
            getObjectByKey[key] = data
        }
    }

    public func getObject(bucket: String, key: String) async throws -> Data? {
        if useKeyedGetObject {
            return getObjectByKey[key]
        }
        guard getObjectIndex < getObjectResults.count else {
            return nil
        }
        let result = getObjectResults[getObjectIndex]
        getObjectIndex += 1
        return result
    }

    public func copyObject(bucket: String, fromKey: String, toKey: String) async throws {
        copyRecords.append((bucket: bucket, fromKey: fromKey, toKey: toKey))
        if let data = getObjectByKey[fromKey] {
            getObjectByKey[toKey] = data
        }
    }

    public func deleteObject(bucket: String, key: String) async throws {
        deleteRecords.append((bucket: bucket, key: key))
        getObjectByKey[key] = nil
    }

    // MARK: - Test helpers

    /// Register a key-addressed getObject response. Enables keyed mode so tests can model an
    /// arbitrary set of existing objects regardless of call order.
    public func setObject(key: String, data: Data) {
        useKeyedGetObject = true
        getObjectByKey[key] = data
    }

    public func getCopyRecords() -> [(bucket: String, fromKey: String, toKey: String)] {
        copyRecords
    }

    public func getDeleteRecords() -> [(bucket: String, key: String)] {
        deleteRecords
    }

    public func setExists(_ exists: Bool) {
        existsResults.append(exists)
    }

    public func setPresignedURL(_ url: String) {
        presignedURLs.append(url)
    }

    public func setError(_ error: Error) {
        errors.append(error)
    }

    public func setGetObjectResult(_ data: Data?) {
        getObjectResults.append(data)
    }

    public func getCallRecords() -> [(bucket: String, key: String)] {
        callRecords
    }

    public func getPresignExpirations() -> [TimeInterval] {
        presignExpirations
    }

    public func getPutRecords() -> [(data: Data, bucket: String, key: String, contentType: String)] {
        putRecords
    }

    public func reset() {
        existsResults.removeAll()
        presignedURLs.removeAll()
        errors.removeAll()
        callRecords.removeAll()
        presignExpirations.removeAll()
        putRecords.removeAll()
        getObjectResults.removeAll()
        getObjectByKey.removeAll()
        useKeyedGetObject = false
        copyRecords.removeAll()
        deleteRecords.removeAll()
        existsIndex = 0
        presignIndex = 0
        getObjectIndex = 0
    }
}
