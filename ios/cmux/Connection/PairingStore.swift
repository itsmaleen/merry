import Foundation
import Security

struct PairingCredentials: Codable, Equatable {
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

// MARK: - Multiple bridges

/// A paired bridge (one Mac), with a stable id and a user-editable display name
/// on top of its connection credentials. A single phone can hold several and
/// switch between them.
struct SavedBridge: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var credentials: PairingCredentials

    init(id: UUID = UUID(), name: String, credentials: PairingCredentials) {
        self.id = id
        self.name = name
        self.credentials = credentials
    }

    /// A friendly default name derived from the bridge's network identity: the
    /// first label of the tailnet host (e.g. "cmux-bridge-mini") when present,
    /// otherwise the LAN host/IP.
    static func defaultName(for c: PairingCredentials) -> String {
        if let ts = c.tailscaleHost, !ts.isEmpty {
            if let first = ts.split(separator: ".").first, !first.isEmpty {
                return String(first)
            }
            return ts
        }
        return c.host
    }
}

/// Persists the set of paired bridges (and which one is active) in the Keychain
/// as a single JSON blob. Migrates a legacy single-pairing entry on first load.
final class BridgeStore {
    private let service = "dev.itsmaleen.cmux-bridge"
    private let account = "bridges.v1"
    private let legacy = PairingStore()

    private struct StoreData: Codable {
        var bridges: [SavedBridge]
        var selectedID: UUID?
    }

    func loadAll() -> (bridges: [SavedBridge], selectedID: UUID?) {
        if let data = readBlob(),
           let decoded = try? JSONDecoder().decode(StoreData.self, from: data) {
            return (decoded.bridges, decoded.selectedID)
        }
        // Migrate a legacy single pairing, if one exists, into the new list.
        if let creds = try? legacy.load() {
            let bridge = SavedBridge(name: SavedBridge.defaultName(for: creds), credentials: creds)
            persist(bridges: [bridge], selectedID: bridge.id)
            try? legacy.delete()
            return ([bridge], bridge.id)
        }
        return ([], nil)
    }

    func persist(bridges: [SavedBridge], selectedID: UUID?) {
        guard let data = try? JSONEncoder().encode(StoreData(bridges: bridges, selectedID: selectedID)) else { return }
        writeBlob(data)
    }

    // MARK: - Keychain

    private func readBlob() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func writeBlob(_ data: Data) {
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
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
