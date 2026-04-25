import Foundation
import Security

nonisolated struct MicrosoftTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var accessTokenExpiresAt: Date
    var scope: String
    var microsoftUserId: String?
    var email: String?
    var displayName: String?
}

nonisolated enum MicrosoftTokenStoreError: Error, Equatable {
    case encoding(String)
    case decoding(String)
    case keychain(OSStatus)
}

nonisolated struct MicrosoftTokenStore: Sendable {
    private let service: String
    private let account: String

    init(
        service: String = "com.omkarpatil.VoxScribe.microsoft",
        account: String = "tokens.v1"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> MicrosoftTokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw MicrosoftTokenStoreError.keychain(status)
        }
        guard let data = item as? Data else {
            throw MicrosoftTokenStoreError.decoding("missing keychain payload")
        }
        do {
            return try Self.decoder.decode(MicrosoftTokens.self, from: data)
        } catch {
            throw MicrosoftTokenStoreError.decoding(String(describing: error))
        }
    }

    func save(_ tokens: MicrosoftTokens) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(tokens)
        } catch {
            throw MicrosoftTokenStoreError.encoding(String(describing: error))
        }

        let query = baseQuery()
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw MicrosoftTokenStoreError.keychain(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw MicrosoftTokenStoreError.keychain(addStatus)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw MicrosoftTokenStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
