@testable import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Mock S3 client for testing
actor MockS3Client: S3ManagerProtocol {

    private var existsResults: [Bool] = []
    private var presignedURLs: [String] = []
    private var errors: [any Error] = []
    private var callRecords: [(bucket: String, key: String)] = []
    private var presignExpirations: [TimeInterval] = []
    private var putRecords: [(data: Data, bucket: String, key: String, contentType: String)] = []
    private var getObjectResults: [Data?] = []
    /// Key-addressed responses. When a key is present here it takes precedence over the sequential
    /// `getObjectResults` queue — useful for tests that issue getObject in a hard-to-predict order.
    private var getObjectByKey: [String: Data] = [:]
    private var useKeyedGetObject = false
    /// When set, `getObject` throws this for any key NOT present in `getObjectByKey` (in keyed mode).
    /// Models S3 read failures on cache-miss keys (e.g. a non-404 error) without disturbing hits.
    private var getObjectMissError: (any Error)?
    private var copyRecords: [(bucket: String, fromKey: String, toKey: String)] = []
    private var deleteRecords: [(bucket: String, key: String)] = []
    private var existsIndex = 0
    private var presignIndex = 0
    private var getObjectIndex = 0

    init() {}

    func objectExists(bucket: String, key: String) async throws -> Bool {
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

    func presignedGetURL(bucket: String, key: String, expiration: TimeInterval) async throws -> URL {
        presignExpirations.append(expiration)

        guard presignIndex < presignedURLs.count else {
            return URL(string: "https://s3.example.com/\(key)")!
        }

        let result = presignedURLs[presignIndex]
        presignIndex += 1
        return URL(string: result)!
    }

    func putObject(data: Data, bucket: String, key: String, contentType: String) async throws {
        putRecords.append((data: data, bucket: bucket, key: key, contentType: contentType))
        if useKeyedGetObject {
            getObjectByKey[key] = data
        }
    }

    func getObject(bucket: String, key: String) async throws -> Data? {
        if useKeyedGetObject {
            if let data = getObjectByKey[key] {
                return data
            }
            if let error = getObjectMissError {
                throw error
            }
            return nil
        }
        guard getObjectIndex < getObjectResults.count else {
            return nil
        }
        let result = getObjectResults[getObjectIndex]
        getObjectIndex += 1
        return result
    }

    func copyObject(bucket: String, fromKey: String, toKey: String) async throws {
        copyRecords.append((bucket: bucket, fromKey: fromKey, toKey: toKey))
        if let data = getObjectByKey[fromKey] {
            getObjectByKey[toKey] = data
        }
    }

    func deleteObject(bucket: String, key: String) async throws {
        deleteRecords.append((bucket: bucket, key: key))
        getObjectByKey[key] = nil
    }

    // MARK: - Test helpers

    /// Register a key-addressed getObject response. Enables keyed mode so tests can model an
    /// arbitrary set of existing objects regardless of call order.
    func setObject(key: String, data: Data) {
        useKeyedGetObject = true
        getObjectByKey[key] = data
    }

    /// Make keyed-mode `getObject` throw for any key without a registered object. Models an S3 read
    /// failure on cache-miss keys. Enables keyed mode so registered objects still resolve as hits.
    func setGetObjectMissError(_ error: any Error) {
        useKeyedGetObject = true
        getObjectMissError = error
    }

    func getCopyRecords() -> [(bucket: String, fromKey: String, toKey: String)] {
        copyRecords
    }

    func getDeleteRecords() -> [(bucket: String, key: String)] {
        deleteRecords
    }

    func setExists(_ exists: Bool) {
        existsResults.append(exists)
    }

    func setPresignedURL(_ url: String) {
        presignedURLs.append(url)
    }

    func setError(_ error: any Error) {
        errors.append(error)
    }

    func setGetObjectResult(_ data: Data?) {
        getObjectResults.append(data)
    }

    func getCallRecords() -> [(bucket: String, key: String)] {
        callRecords
    }

    func getPresignExpirations() -> [TimeInterval] {
        presignExpirations
    }

    func getPutRecords() -> [(data: Data, bucket: String, key: String, contentType: String)] {
        putRecords
    }

    func reset() {
        existsResults.removeAll()
        presignedURLs.removeAll()
        errors.removeAll()
        callRecords.removeAll()
        presignExpirations.removeAll()
        putRecords.removeAll()
        getObjectResults.removeAll()
        getObjectByKey.removeAll()
        useKeyedGetObject = false
        getObjectMissError = nil
        copyRecords.removeAll()
        deleteRecords.removeAll()
        existsIndex = 0
        presignIndex = 0
        getObjectIndex = 0
    }
}
