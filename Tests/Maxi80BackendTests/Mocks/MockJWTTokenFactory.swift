import Foundation
import Maxi80Backend

/// Mock JWT token factory for testing, using actor isolation for thread safety.
actor MockJWTTokenFactory: JWTTokenFactoryProtocol {

    struct CallRecord: Sendable {
        let action: Action
        let token: String?

        enum Action: Equatable, Sendable {
            case generateJWTString
            case validateJWTString(String?)
        }
    }

    private var callRecords: [CallRecord] = []
    private var generateTokenResponses: [Result<String, any Error>] = []
    private var validateTokenResponses: [Bool] = []
    private var generateIndex = 0
    private var validateIndex = 0

    init() {}

    func generateJWTString() async throws -> String {
        let record = CallRecord(action: .generateJWTString, token: nil)
        callRecords.append(record)

        guard generateIndex < generateTokenResponses.count else {
            throw MockError.noResponseConfigured
        }

        let result = generateTokenResponses[generateIndex]
        generateIndex += 1

        switch result {
        case .success(let token):
            return token
        case .failure(let error):
            throw error
        }
    }

    func validateJWTString(token: String?) async -> Bool {
        let record = CallRecord(action: .validateJWTString(token), token: token)
        callRecords.append(record)

        guard validateIndex < validateTokenResponses.count else {
            return false
        }

        let result = validateTokenResponses[validateIndex]
        validateIndex += 1
        return result
    }

    // Test helper methods
    func setGenerateTokenResponse(_ token: String) {
        generateTokenResponses.append(.success(token))
    }

    func setGenerateTokenError(_ error: any Error) {
        generateTokenResponses.append(.failure(error))
    }

    func setValidateTokenResponse(_ isValid: Bool) {
        validateTokenResponses.append(isValid)
    }

    func getCallRecords() -> [CallRecord] {
        callRecords
    }

    func reset() {
        callRecords.removeAll()
        generateTokenResponses.removeAll()
        validateTokenResponses.removeAll()
        generateIndex = 0
        validateIndex = 0
    }
}

enum MockError: Error {
    case noResponseConfigured
    case invalidToken
}
