import Foundation

final class MemorySecrets: RemotePlaySecretStorage {
    var items: [String: Data] = [:]
    var failWrites = false
    func read(_ key: String) throws -> Data? { items[key] }
    func write(_ data: Data, key: String) throws {
        if failWrites { throw RemotePlayCredentialError.storage(-1) }
        items[key] = data
    }
    func delete(_ key: String) throws { items.removeValue(forKey: key) }
}

func check(_ condition: @autoclosure () throws -> Bool) rethrows {
    let valid = try condition()
    precondition(valid)
}

@main struct CredentialTests {
    static func main() throws {
        let account = Data(repeating: 7, count: 8)
        try check(RemotePlayCredentials.parseAccountID(account.base64EncodedString()) == account)
        for bad in ["", "123", Data(repeating: 0, count: 7).base64EncodedString(), "!!!!"] {
            do { _ = try RemotePlayCredentials.parseAccountID(bad); fatalError("accepted bad account") }
            catch { }
        }
        try check(RemotePlayCredentials.parsePIN("00123456") == 123456)
        for bad in ["1234567", "123456789", "abcdefgh", "１２３４５６７８"] {
            do { _ = try RemotePlayCredentials.parsePIN(bad); fatalError("accepted bad PIN") }
            catch { }
        }
        let suite = "ps5mcp.credentials-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets()
        let store = RemotePlayCredentialStore(secrets: secrets, defaults: defaults)
        let credential = try RemotePlayCredentials(consoleID: "aabbccddeeff", nickname: "PS5",
            accountID: account, registrationKey: Data(repeating: 1, count: 16),
            sessionKey: Data(repeating: 2, count: 16), host: "192.0.2.1")
        secrets.failWrites = true
        do { try store.save(credential); fatalError("ignored failed secret storage") } catch { }
        try check(store.load(host: credential.host) == nil)
        secrets.failWrites = false
        try store.save(credential)
        let loaded = try store.load(host: credential.host)
        assert(loaded == credential)
        try check(store.load(host: "192.0.2.2") == nil)
        assert(!defaults.dictionaryRepresentation().values.contains { String(describing: $0).contains(credential.sessionKey.base64EncodedString()) })
        // A corrupt/obsolete Keychain record must not become usable credentials.
        let key = credential.storageKey
        secrets.items[key] = Data("{}".utf8)
        do { _ = try store.load(host: credential.host); fatalError("accepted corrupt record") } catch { }
        try store.save(credential)
        try store.forget(host: credential.host)
        try check(store.load(host: credential.host) == nil)
        assert(secrets.items.isEmpty)
        do {
            _ = try RemotePlayCredentials(consoleID: "bad", nickname: "PS5", accountID: account,
                registrationKey: Data(), sessionKey: Data(), host: "192.0.2.1")
            fatalError("accepted invalid key lengths")
        } catch { }
        print("credential checks passed")
    }
}
