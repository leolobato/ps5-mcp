// Pairing material is stored in Keychain; preferences contain only profile references.
import Foundation
import Security

enum RemotePlayCredentialError: LocalizedError {
    case invalidAccount, invalidPIN, invalidRecord, storage(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidAccount: return "Account ID must be Base64 encoding exactly eight bytes."
        case .invalidPIN: return "Enter the eight-digit pairing PIN shown on the PS5."
        case .invalidRecord: return "Remote Play registration is invalid. Forget it and pair again."
        case .storage(let status): return "Could not access Remote Play credentials in Keychain (\(status))."
        }
    }
}

struct RemotePlayCredentials: Codable, Equatable {
    let consoleID: String
    let nickname: String
    let accountID: Data
    let registrationKey: Data
    let sessionKey: Data
    let host: String

    init(consoleID: String, nickname: String, accountID: Data, registrationKey: Data,
         sessionKey: Data, host: String) throws {
        self.consoleID = consoleID.lowercased()
        self.nickname = nickname
        self.accountID = accountID
        self.registrationKey = registrationKey
        self.sessionKey = sessionKey
        self.host = host
        try validate()
    }

    func validate() throws {
        guard consoleID.count == 12, consoleID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              accountID.count == 8, registrationKey.count == 16, sessionKey.count == 16,
              !host.isEmpty else { throw RemotePlayCredentialError.invalidRecord }
    }

    var consoleMAC: Data {
        let bytes = Array(consoleID.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).compactMap {
            UInt8(String(bytes: bytes[$0..<$0 + 2], encoding: .utf8)!, radix: 16)
        })
    }
    var storageKey: String { consoleID + ":" + accountID.base64EncodedString() }

    static func parseAccountID(_ text: String) throws -> Data {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 8 else { throw RemotePlayCredentialError.invalidAccount }
        return data
    }

    static func parsePIN(_ text: String) throws -> UInt32 {
        let pin = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pin.utf8.count == 8, pin.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt32(pin) else { throw RemotePlayCredentialError.invalidPIN }
        return value
    }
}

protocol RemotePlaySecretStorage {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func delete(_ key: String) throws
}

struct RemotePlayKeychain: RemotePlaySecretStorage {
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ps5-mcp.remoteplay",
         kSecAttrAccount as String: key]
    }
    func read(_ key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RemotePlayCredentialError.storage(status) }
        guard let data = result as? Data else { throw RemotePlayCredentialError.invalidRecord }
        return data
    }
    func write(_ data: Data, key: String) throws {
        let request = query(key)
        var status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = request
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RemotePlayCredentialError.storage(status) }
    }
    func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemotePlayCredentialError.storage(status)
        }
    }
}

final class RemotePlayCredentialStore {
    private let secrets: RemotePlaySecretStorage
    private let defaults: UserDefaults
    private let referencesKey = "remotePlayProfiles"
    init(secrets: RemotePlaySecretStorage = RemotePlayKeychain(), defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults
    }
    private var references: [String: String] { defaults.dictionary(forKey: referencesKey) as? [String: String] ?? [:] }
    func save(_ credentials: RemotePlayCredentials) throws {
        try credentials.validate()
        try secrets.write(JSONEncoder().encode(credentials), key: credentials.storageKey)
        var refs = references
        refs[credentials.host] = credentials.storageKey
        defaults.set(refs, forKey: referencesKey)
    }
    func load(host: String) throws -> RemotePlayCredentials? {
        guard let key = references[host], let data = try secrets.read(key) else { return nil }
        let record = try JSONDecoder().decode(RemotePlayCredentials.self, from: data)
        try record.validate()
        guard record.storageKey == key else { throw RemotePlayCredentialError.invalidRecord }
        return record
    }
    func forget(host: String) throws {
        var refs = references
        guard let key = refs[host] else { return }
        try secrets.delete(key)
        refs = refs.filter { $0.value != key }
        defaults.set(refs, forKey: referencesKey)
    }
}
