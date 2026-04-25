import Foundation

nonisolated enum MicrosoftOAuthConfig {
    static let clientId = "2c5a12d1-411d-4b5f-a1d4-1bff67c29e73"

    static let redirectURI = "msauth.com.omkarpatil.VoxScribe://auth"

    static let callbackScheme = "msauth.com.omkarpatil.VoxScribe"

    static let authorizeURL = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize")!
    static let tokenURL = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!

    static let graphMeURL = URL(string: "https://graph.microsoft.com/v1.0/me")!
    static let graphRootUploadBase = "https://graph.microsoft.com/v1.0/me/drive/root:/"

    static let scopes: [String] = [
        "openid",
        "profile",
        "offline_access",
        "Files.ReadWrite",
        "User.Read",
    ]

    static var scopeString: String { scopes.joined(separator: " ") }
}
