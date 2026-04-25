import Foundation
import AuthenticationServices
import UIKit

enum MicrosoftAuthError: Error, Equatable {
    case userCancelled
    case cannotStartSession
    case missingCallback
    case invalidCallback(String)
    case stateMismatch
    case authorizationErrorResponse(String)
    case tokenExchangeFailed(status: Int, body: String)
    case tokenExchangeMalformed(String)
    case profileFetchFailed(status: Int)
    case profileMalformed(String)
    case storageFailed(String)
    case transport(String)
}

@MainActor
final class MicrosoftAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let tokenStore: MicrosoftTokenStore
    private let urlSession: URLSession
    private var activeSession: ASWebAuthenticationSession?

    init(
        tokenStore: MicrosoftTokenStore = MicrosoftTokenStore(),
        urlSession: URLSession = .shared
    ) {
        self.tokenStore = tokenStore
        self.urlSession = urlSession
    }

    func connect() async throws -> MicrosoftTokens {
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.makeState()

        let authURL = buildAuthorizeURL(challenge: challenge, state: state)
        let callback = try await presentAuth(url: authURL)

        try validateCallback(callback, expectedState: state)
        let code = try extractCode(from: callback)

        let response = try await exchangeCode(code: code, verifier: verifier)
        let profile = try await fetchMe(accessToken: response.accessToken)

        let tokens = MicrosoftTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            accessTokenExpiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            scope: response.scope ?? MicrosoftOAuthConfig.scopeString,
            microsoftUserId: profile.id,
            email: profile.email,
            displayName: profile.displayName
        )
        do {
            try tokenStore.save(tokens)
        } catch {
            throw MicrosoftAuthError.storageFailed(String(describing: error))
        }
        return tokens
    }

    private func buildAuthorizeURL(challenge: String, state: String) -> URL {
        var comps = URLComponents(url: MicrosoftOAuthConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: MicrosoftOAuthConfig.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: MicrosoftOAuthConfig.redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: MicrosoftOAuthConfig.scopeString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return comps.url!
    }

    private func presentAuth(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: MicrosoftOAuthConfig.callbackScheme
            ) { [weak self] callback, error in
                Task { @MainActor in self?.activeSession = nil }
                if let nsError = error as NSError?,
                   nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                   nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    continuation.resume(throwing: MicrosoftAuthError.userCancelled)
                    return
                }
                if let error {
                    continuation.resume(throwing: MicrosoftAuthError.transport(String(describing: error)))
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: MicrosoftAuthError.missingCallback)
                    return
                }
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.activeSession = session
            if !session.start() {
                self.activeSession = nil
                continuation.resume(throwing: MicrosoftAuthError.cannotStartSession)
            }
        }
    }

    private func validateCallback(_ url: URL, expectedState: String) throws {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MicrosoftAuthError.invalidCallback("unparseable url")
        }
        let items = comps.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? ""
            throw MicrosoftAuthError.authorizationErrorResponse("\(err): \(desc)")
        }
        guard let state = items.first(where: { $0.name == "state" })?.value else {
            throw MicrosoftAuthError.invalidCallback("missing state")
        }
        guard state == expectedState else {
            throw MicrosoftAuthError.stateMismatch
        }
    }

    private func extractCode(from url: URL) throws -> String {
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw MicrosoftAuthError.invalidCallback("missing code")
        }
        return code
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let scope: String?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
        }
    }

    private func exchangeCode(code: String, verifier: String) async throws -> TokenResponse {
        var req = URLRequest(url: MicrosoftOAuthConfig.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        req.httpBody = formEncode([
            "client_id": MicrosoftOAuthConfig.clientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": MicrosoftOAuthConfig.redirectURI,
            "code_verifier": verifier,
            "scope": MicrosoftOAuthConfig.scopeString,
        ]).data(using: .utf8)

        let (data, response) = try await urlSessionData(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftAuthError.tokenExchangeFailed(status: 0, body: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MicrosoftAuthError.tokenExchangeFailed(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw MicrosoftAuthError.tokenExchangeMalformed(String(describing: error))
        }
    }

    private struct MeResponse: Decodable {
        let id: String
        let mail: String?
        let userPrincipalName: String?
        let displayName: String?

        var email: String? { mail ?? userPrincipalName }
    }

    private func fetchMe(accessToken: String) async throws -> MeResponse {
        var req = URLRequest(url: MicrosoftOAuthConfig.graphMeURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        let (data, response) = try await urlSessionData(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftAuthError.profileFetchFailed(status: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MicrosoftAuthError.profileFetchFailed(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(MeResponse.self, from: data)
        } catch {
            throw MicrosoftAuthError.profileMalformed(String(describing: error))
        }
    }

    private func urlSessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await urlSession.data(for: request) }
        catch { throw MicrosoftAuthError.transport(String(describing: error)) }
    }

    private func formEncode(_ pairs: [String: String]) -> String {
        // Explicitly escape +, &, =, and space so Microsoft's form parser
        // can't confuse any of our values for delimiters.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&= ")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            if let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first {
                return window
            }
            if let scene {
                return UIWindow(windowScene: scene)
            }
            return UIWindow()
        }
    }
}
