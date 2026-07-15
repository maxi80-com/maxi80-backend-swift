import Logging
import Testing

@testable import Maxi80Backend

@Suite("AppleMusicAuthProvider Tests")
struct AppleMusicAuthProviderTests {

    struct TokenReuseTestCase: CustomStringConvertible, Sendable {
        let callCount: Int
        var description: String { "callCount=\(callCount)" }
    }

    static func generateTokenReuseTestCases(count: Int) -> [TokenReuseTestCase] {
        // Each test case calls authorizationHeader() between 2 and 5 times
        // with a valid cached token — generateJWTString should only be called once
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in
            TokenReuseTestCase(callCount: Int.random(in: 2...5, using: &rng))
        }
    }

    // Feature: icecast-metadata-collector, Property 8: Token cache reuse
    /// **Validates: Requirements 3.3**
    @Test(
        "Property 8: Token cache reuse",
        arguments: generateTokenReuseTestCases(count: 100)
    )
    func tokenCacheReuse(testCase: TokenReuseTestCase) async throws {
        let mockFactory = MockJWTTokenFactory()

        // First call generates a token
        await mockFactory.setGenerateTokenResponse("cached-token-\(testCase.callCount)")

        // All subsequent validate calls return true (token is still valid)
        for _ in 0..<testCase.callCount {
            await mockFactory.setValidateTokenResponse(true)
        }

        let provider = AppleMusicAuthProvider(
            tokenFactory: mockFactory
        )

        // Call authorizationHeader() multiple times
        var lastHeader: [String: String]? = nil
        let logger = Logger(label: "test")
        for _ in 0..<testCase.callCount {
            let header = try await provider.authorizationHeader(logger: logger)
            lastHeader = header
        }

        // Verify: generateJWTString should have been called exactly once
        let calls = await mockFactory.getCallRecords()
        let generateCalls = calls.filter { $0.action == .generateJWTString }
        #expect(
            generateCalls.count == 1,
            "generateJWTString should be called exactly once, was called \(generateCalls.count) times"
        )

        // Verify: the returned header should contain the cached token
        #expect(lastHeader?["Authorization"] == "Bearer cached-token-\(testCase.callCount)")
    }
}
