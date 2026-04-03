import Foundation
import Security

struct PairingCredentials: Codable {
    let host: String
    let port: Int
    let token: String
    let tailscaleHost: String?

    init(host: String, port: Int, token: String, tailscaleHost: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.tailscaleHost = tailscaleHost
    }
}

final class PairingStore {
    private let service = "dev.itsmaleen.cmux-bridge"
    private let account = "credentials"

    func save(_ credentials: PairingCredentials) throws {
        let data = try JSONEncoder().encode(credentials)

        // Delete any existing entry first
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func load() throws -> PairingCredentials {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.notFound
        }
        return try JSONDecoder().decode(PairingCredentials.self, from: data)
    }

    func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
    case notFound
    case deleteFailed(OSStatus)
}
