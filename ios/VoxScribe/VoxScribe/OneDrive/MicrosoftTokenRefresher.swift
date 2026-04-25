import Foundation

nonisolated enum MicrosoftTokenRefreshError: Error, Equatable {
    case notConnected
    case terminalAuthFailure(String)
    case transport(String)
    case malformed(String)
    case tokenExchangeFailed(status: Int, body: String)
    case storageFailed(String)
}

/// Every Graph call goes through `validAccessToken` so the token-refresh
/// path can rotate the refresh token atomically. Actor-isolated so that
/// concurrent callers coalesce onto a single in-flight refresh.
actor MicrosoftTokenRefresher {
    private let tokenStore: MicrosoftTokenStore
    private let urlSession: URLSession
    private let refreshSkew: TimeInterval
    private var inflightRefresh: Task<MicrosoftTokens, Error>?

    static let terminalErrorCodes: Set<String> = [
        "invalid_grant",
        "interaction_required",
        "login_required",
        "consent_required",
        "unauthorized_client",
    ]

    init(
        tokenStore: MicrosoftTokenStore = MicrosoftTokenStore(),
        urlSession: URLSession = .shared,
        refreshSkew: TimeInterval = 120
    ) {
        self.tokenStore = tokenStore
        self.urlSession = urlSession
        self.refreshSkew = refreshSkew
    }

    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if let inflight = inflightRefresh {
            let tokens = try await inflight.value
            return tokens.accessToken
        }

        let current = try loadOrThrow()
        if !forceRefresh && Date().addingTimeInterval(refreshSkew) < current.accessTokenExpiresAt {
            return current.accessToken
        }

        let task = Task<MicrosoftTokens, Error> { [self] in
            try await performRefresh(using: current.refreshToken, previous: current)
        }
        inflightRefresh = task
        do {
            let refreshed = try await task.value
            inflightRefresh = nil
            return refreshed.accessToken
        } catch {
            inflightRefresh = nil
            throw error
        }
    }

    func isConnected() -> Bool {
        (try? tokenStore.load()) != nil
    }

    func disconnect() throws {
        do { try tokenStore.clear() }
        catch { throw MicrosoftTokenRefreshError.storageFailed(String(describing: error)) }
    }

    private func loadOrThrow() throws -> MicrosoftTokens {
        do {
            guard let tokens = try tokenStore.load() else {
                throw MicrosoftTokenRefreshError.notConnected
            }
            return tokens
        } catch let error as MicrosoftTokenRefreshError {
            throw error
        } catch {
            throw MicrosoftTokenRefreshError.storageFailed(String(describing: error))
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private func performRefresh(using refreshToken: String, previous: MicrosoftTokens) async throws -> MicrosoftTokens {
        var req = URLRequest(url: MicrosoftOAuthConfig.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        req.httpBody = Self.formEncode([
            "client_id": MicrosoftOAuthConfig.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": MicrosoftOAuthConfig.scopeString,
        ]).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await urlSession.data(for: req) }
        catch { throw MicrosoftTokenRefreshError.transport(String(describing: error)) }

        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftTokenRefreshError.tokenExchangeFailed(status: 0, body: "")
        }

        if http.statusCode == 400 || http.statusCode == 401 {
            if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
               Self.terminalErrorCodes.contains(oauthError.error) {
                try? tokenStore.clear()
                throw MicrosoftTokenRefreshError.terminalAuthFailure(oauthError.error)
            }
            throw MicrosoftTokenRefreshError.tokenExchangeFailed(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            throw MicrosoftTokenRefreshError.tokenExchangeFailed(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let parsed: TokenResponse
        do { parsed = try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw MicrosoftTokenRefreshError.malformed(String(describing: error)) }

        let updated = MicrosoftTokens(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken ?? previous.refreshToken,
            accessTokenExpiresAt: Date().addingTimeInterval(TimeInterval(parsed.expiresIn)),
            scope: parsed.scope ?? previous.scope,
            microsoftUserId: previous.microsoftUserId,
            email: previous.email,
            displayName: previous.displayName
        )
        do { try tokenStore.save(updated) }
        catch { throw MicrosoftTokenRefreshError.storageFailed(String(describing: error)) }
        return updated
    }

    private static func formEncode(_ pairs: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&= ")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
