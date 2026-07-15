public import Logging

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Protocol for providing authorization headers.
public protocol AuthorizationProvider {
    func authorizationHeader(logger: Logger) async throws -> [String: String]
}

/// Provides Apple Music authorization headers with token caching.
public struct AppleMusicAuthProvider: AuthorizationProvider {
    private let tokenFactory: any JWTTokenFactoryProtocol
    private let tokenCache = TokenCache()

    actor TokenCache {
        private var authTokenString: String? = nil
        func setToken(_ token: String) {
            self.authTokenString = token
        }
        func getToken() -> String? {
            self.authTokenString
        }
    }

    public init(tokenFactory: any JWTTokenFactoryProtocol) {
        self.tokenFactory = tokenFactory
    }

    public func authorizationHeader(logger: Logger) async throws -> [String: String] {
        let token: String

        if let authToken = await self.tokenCache.getToken(),
            await tokenFactory.validateJWTString(token: authToken)
        {
            logger.debug("Re-using a valid Apple Music Auth Token")
            token = authToken
        } else {
            logger.debug("No Apple Music Auth Token or it is expired, generating a new one")
            token = try await self.tokenFactory.generateJWTString()
            await self.tokenCache.setToken(token)
        }
        return ["Authorization": "Bearer \(token)"]
    }
}
