// Offline-account setup transport. It never starts or changes anything without an explicit UI action.
import Foundation
import Security

struct RemotePlaySetupAccount: Decodable, Equatable {
    let userId: UInt32
    let name: String
    let slot: Int
    let accountIdB64: String
    let activated: Bool
    let signedIn: Bool
    let foreground: Bool
    let preparationVerified: Bool

    func validate() throws {
        guard (1...16).contains(slot) else { throw RemotePlaySetupError("The helper returned an invalid account slot.") }
        _ = try RemotePlayCredentials.parseAccountID(accountIdB64)
    }
}

struct RemotePlaySetupSnapshot: Decodable {
    let ok: Bool
    let helper: String
    let version: Int
    let capabilities: [String]
    let firmware: String
    let accounts: [RemotePlaySetupAccount]
}

struct RemotePlaySetupPreparation {
    let account: RemotePlaySetupAccount
    let backupPath: String
}

struct RemotePlaySetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class RemotePlaySetupRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Confined to the main thread. The target is immutable, including throughout upload/launch chains.
/// All completion callbacks execute on the main thread; cancel invalidates queued callbacks immediately.
final class RemotePlaySetupClient {
    static let requiredCapabilities = ["compare-before-write", "preserve-existing-id", "target-slot-only",
                                       "durable-backup", "checked-readback", "session-auth"]
    static let tokenMarker = Data("PS5MCP_REMOTEPLAY_SETUP_TOKEN_UNCONFIGURED_CHANGE_BEFORE_UPLOAD_".utf8)
    private final class HelperSession {
        let token: String
        var expires: TimeInterval
        var preparationPending = false
        var lastPreparationError: String?
        init(token: String) { self.token = token; expires = ProcessInfo.processInfo.systemUptime + 900 }
    }
    // Memory only, shared across wizard windows for this app run. Never preferences or logs.
    private static var helperSessions: [String: HelperSession] = [:]
    static func clearHelperSessionsForTesting() { helperSessions = [:] }
    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemotePlaySetupError("Could not create a private helper session.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func personalizedPayload(_ payload: Data, token: String) throws -> Data {
        guard token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let range = payload.range(of: tokenMarker),
              payload.range(of: tokenMarker, in: range.upperBound..<payload.endIndex) == nil else {
            throw RemotePlaySetupError("The bundled setup helper has an invalid session marker. Rebuild the app.")
        }
        var patched = payload
        patched.replaceSubrange(range, with: Data(token.utf8))
        return patched
    }
    let host: String
    private let session: URLSession
    private let authorizeMutation: () throws -> Void
    private var helperStatusPath = "/api/accounts"
    private var inspected: RemotePlaySetupSnapshot?
    private var generation: UInt64 = 0
    private var task: URLSessionDataTask?
    private var preparationTask = false
    private var helperSession: HelperSession
    private let makeToken: () throws -> String

    init(host: String, session: URLSession = .shared,
         authorizeMutation: @escaping () throws -> Void = {},
         makeToken: @escaping () throws -> String = RemotePlaySetupClient.randomToken) throws {
        guard !host.isEmpty, host.rangeOfCharacter(from: CharacterSet(charactersIn: " /:\\?#@\t\r\n")) == nil,
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }) else {
            throw RemotePlaySetupError("Save a valid PS5 IP address in Settings first.")
        }
        self.host = host.lowercased()
        self.session = URLSession(configuration: session.configuration,
                                  delegate: RemotePlaySetupRedirectGuard(), delegateQueue: nil)
        self.makeToken = makeToken
        if let existing = Self.helperSessions[self.host], existing.expires > ProcessInfo.processInfo.systemUptime {
            helperSession = existing
        } else {
            helperSession = HelperSession(token: try makeToken())
            Self.helperSessions[self.host] = helperSession
        }
        self.authorizeMutation = authorizeMutation
    }

    func cancel() {
        precondition(Thread.isMainThread)
        generation &+= 1
        // Closing the wizard cannot undo a POST already accepted by the console.
        // Keep its transport alive and retain diagnostics; a reopened wizard can inspect.
        if !preparationTask { task?.cancel(); task = nil }
        inspected = nil
    }

    private func begin() -> UInt64 {
        precondition(Thread.isMainThread)
        guard !preparationTask else { return generation }
        generation &+= 1
        task?.cancel(); task = nil
        return generation
    }

    private func url(port: Int, path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents()
        parts.scheme = "http"; parts.host = host; parts.port = port; parts.path = path
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }

    private func request(_ request: URLRequest, generation token: UInt64, preparation: Bool = false,
                         completion: @escaping (Result<(Int, Data), Error>) -> Void) {
        guard !preparationTask else {
            completion(.failure(RemotePlaySetupError("Account preparation is still in progress. Wait, then inspect before continuing."))); return
        }
        var request = request
        if request.url?.port == 6770 {
            // Another client (automatic admission, another wizard) may have redeployed the helper with a new token.
            if let shared = Self.helperSessions[host], shared !== helperSession { helperSession = shared }
            request.setValue("Bearer " + helperSession.token, forHTTPHeaderField: "Authorization")
        }
        preparationTask = preparation
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        task = session.dataTask(with: request) { [self] data, response, error in
            DispatchQueue.main.async {
                self.task = nil
                self.preparationTask = false
                if preparation {
                    let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    self.helperSession.preparationPending = error != nil || object?["ok"] as? Bool == nil
                    self.helperSession.lastPreparationError = self.helperSession.preparationPending
                        ? "The previous preparation response is uncertain. Inspect account state before another confirmed attempt."
                        : nil
                }
                guard token == self.generation else { return }
                if let error { completion(.failure(error)); return }
                guard let response = response as? HTTPURLResponse, let data, data.count <= 1_048_576 else {
                    completion(.failure(RemotePlaySetupError("The setup service returned an invalid response."))); return
                }
                completion(.success((response.statusCode, data)))
            }
        }
        task?.resume()
    }

    private func requireSuccess(_ status: Int) throws {
        if status == 401 {
            throw RemotePlaySetupError("The setup helper belongs to another or expired session. Stop that helper on the console, or wait up to 15 minutes, then click Start Setup Helper.")
        }
        guard (200..<300).contains(status) else {
            throw RemotePlaySetupError("The setup service returned HTTP \(status). Inspect the console before trying again.")
        }
    }

    func inspect(completion: @escaping (Result<RemotePlaySetupSnapshot, Error>) -> Void) {
        let token = begin()
        inspected = nil
        request(URLRequest(url: url(port: 6770, path: "/api/accounts")), generation: token) { [weak self] result in
            do {
                let (status, data) = try result.get()
                try self?.requireSuccess(status)
                guard let self else { return }
                let snapshot = try self.decodeSnapshot(data)
                self.inspected = snapshot
                completion(.success(snapshot))
            } catch { completion(.failure(error)) }
        }
    }

    func admission(mode: RemotePlayAdmissionMode, requestID: String, expectedBuildID: String,
                   completion: @escaping (Result<RemotePlayAdmissionReport, Error>) -> Void) {
        let token = begin()
        do {
            guard requestID.count == 32, requestID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw RemotePlaySetupError("Invalid Remote Play operation identity.")
            }
            if mode != .check { try authorizeMutation() }
            var request = URLRequest(url: url(port: 6770, path: "/api/admission"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            if mode != .check { request.setValue("1", forHTTPHeaderField: "X-RemotePlay-Setup") }
            request.httpBody = Data("mode=\(mode.rawValue)&requestId=\(requestID)".utf8)
            self.request(request, generation: token) { result in
                do {
                    let (status, data) = try result.get()
                    if status == 401 { try self.requireSuccess(status) }
                    let report = try JSONDecoder().decode(RemotePlayAdmissionReport.self, from: data)
                    try report.validate(mode: mode, requestID: requestID, buildID: expectedBuildID)
                    try self.requireSuccess(status)
                    completion(.success(report))
                } catch { completion(.failure(error)) }
            }
        } catch { completion(.failure(error)) }
    }

    func prepare(account: RemotePlaySetupAccount, confirmed: Bool,
                 completion: @escaping (Result<RemotePlaySetupPreparation, Error>) -> Void) {
        let token = begin()
        do {
            guard confirmed, inspected?.accounts.contains(account) == true else {
                throw RemotePlaySetupError("Inspect accounts and confirm the exact user before preparing Remote Play.")
            }
            try authorizeMutation()
            try account.validate()
            // A failure or uncertain write always requires fresh inspection and fresh consent.
            inspected = nil
            let encodedID = account.accountIdB64.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            var request = URLRequest(url: url(port: 6770, path: "/api/prepare"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "X-RemotePlay-Setup")
            request.httpBody = Data("userId=\(account.userId)&slot=\(account.slot)&expectedAccountIdB64=\(encodedID)".utf8)
            helperSession.preparationPending = true
            self.request(request, generation: token, preparation: true) { result in
                do {
                    let (status, data) = try result.get()
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw RemotePlaySetupError("The preparation result could not be verified. Inspect before trying again.")
                    }
                    let backup = object["backupPath"] as? String ?? ""
                    let partial = object["partialWrites"] as? Bool == true
                    guard (200..<300).contains(status), object["ok"] as? Bool == true, !partial else {
                        let code = String((object["code"] as? String ?? "unknown").prefix(100))
                        let message = String((object["message"] as? String ?? "Preparation failed.").prefix(1000))
                        let restored = partial && object["restored"] as? Bool == true
                        let recovery = restored
                            ? " Writes were rolled back and verified. Preparation failed; inspect before another confirmed attempt."
                            : partial ? " Some account values may have changed. Stop and inspect; do not repeat preparation." : " Inspect before trying again."
                        throw RemotePlaySetupError("\(message) (\(code)).\(recovery)" + (backup.isEmpty ? "" : " Backup: \(backup)"))
                    }
                    guard let values = object["account"], (!backup.isEmpty || object["noOp"] as? Bool == true),
                          object["requiresUserReboot"] as? Bool == false,
                          object["partialWrites"] as? Bool == false else {
                        throw RemotePlaySetupError("Preparation returned an incomplete result. Inspect before trying again.")
                    }
                    let prepared = try JSONDecoder().decode(RemotePlaySetupAccount.self,
                        from: JSONSerialization.data(withJSONObject: values))
                    try prepared.validate()
                    let previousID = try RemotePlayCredentials.parseAccountID(account.accountIdB64)
                    guard prepared.userId == account.userId, prepared.slot == account.slot,
                          prepared.preparationVerified, prepared.activated,
                          prepared.accountIdB64 != "AAAAAAAAAAA=",
                          previousID.allSatisfy({ $0 == 0 }) || prepared.accountIdB64 == account.accountIdB64 else {
                        throw RemotePlaySetupError("Preparation readback did not match the selected account. Stop and inspect. Backup: \(backup)")
                    }
                    completion(.success(RemotePlaySetupPreparation(account: prepared, backupPath: backup)))
                } catch { completion(.failure(error)) }
            }
        } catch { completion(.failure(error)) }
    }

    /// A new launch requires an explicit action, authenticates an existing session before
    /// stopping it, personalizes the ELF, and verifies the new listener after loader success.
    func startHelper(payload: Data, inspectAccounts: Bool = true, completion: @escaping (Result<Void, Error>) -> Void) {
        let token = begin()
        helperStatusPath = inspectAccounts ? "/api/accounts" : "/api/status"
        inspected = nil
        do {
            guard !preparationTask else { throw RemotePlaySetupError("Account preparation is still in progress. Wait and inspect before restarting the helper.") }
            try authorizeMutation()
            // Validate the bundle before touching the console; this also rejects duplicate markers.
            let newSession = HelperSession(token: try makeToken())
            let patched = try Self.personalizedPayload(payload, token: newSession.token)
            request(URLRequest(url: url(port: 6770, path: helperStatusPath)), generation: token) { [self] result in
                switch result {
                case .failure(let error):
                    guard (error as? URLError)?.code == .cannotConnectToHost else {
                        completion(.failure(RemotePlaySetupError("Could not establish whether a setup helper is running. Inspect the console before starting another helper."))); return
                    }
                    deploy(patched, helper: newSession, generation: token, completion: completion)
                case .success(let (status, data)):
                    do {
                        try requireSuccess(status)
                        _ = try decodeSnapshot(data)
                        try authorizeMutation()
                        var stop = URLRequest(url: url(port: 6770, path: "/api/shutdown"))
                        stop.httpMethod = "POST"; stop.httpBody = Data()
                        stop.setValue("1", forHTTPHeaderField: "X-RemotePlay-Setup")
                        request(stop, generation: token) { [self] result in
                            do {
                                let (status, _) = try result.get(); try requireSuccess(status)
                                deploy(patched, helper: newSession, generation: token, completion: completion)
                            } catch { completion(.failure(error)) }
                        }
                    } catch { completion(.failure(error)) }
                }
            }
        } catch { completion(.failure(error)) }
    }

    private func decodeSnapshot(_ data: Data) throws -> RemotePlaySetupSnapshot {
        let snapshot = try JSONDecoder().decode(RemotePlaySetupSnapshot.self, from: data)
        guard snapshot.ok, snapshot.helper == "ps5mcp-remoteplay-setup", snapshot.version == 1,
              Set(Self.requiredCapabilities).isSubset(of: Set(snapshot.capabilities)) else {
            throw RemotePlaySetupError("This is not the supported authenticated setup helper. Account changes are blocked.")
        }
        for account in snapshot.accounts { try account.validate() }
        guard Set(snapshot.accounts.map(\.slot)).count == snapshot.accounts.count,
              Set(snapshot.accounts.map(\.userId)).count == snapshot.accounts.count else {
            throw RemotePlaySetupError("The helper returned ambiguous accounts. Account changes are blocked.")
        }
        return snapshot
    }

    private func deploy(_ payload: Data, helper: HelperSession, generation token: UInt64,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try authorizeMutation()
            helperSession = helper; Self.helperSessions[host] = helper
            var upload = URLRequest(url: url(port: 8084, path: "/manage:upload",
                query: [URLQueryItem(name: "filename", value: "ps5mcp-remoteplay-setup.elf")]))
            upload.httpMethod = "POST"; upload.httpBody = payload
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request(upload, generation: token) { [self] result in
                do {
                    let (status, _) = try result.get(); try requireSuccess(status)
                    try authorizeMutation()
                    request(URLRequest(url: url(port: 8084, path: "/list_payloads")), generation: token) { [self] result in
                        do {
                            let (status, data) = try result.get(); try requireSuccess(status)
                            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                            let paths = object?["payloads"] as? [String] ?? []
                            let matches = paths.filter { $0.hasSuffix("/ps5mcp-remoteplay-setup.elf") && $0.hasPrefix("/") }
                            guard matches.count == 1 else { throw RemotePlaySetupError("The uploaded setup helper could not be identified uniquely.") }
                            try authorizeMutation()
                            request(URLRequest(url: url(port: 8084, path: "/loadpayload:" + matches[0])), generation: token) { [self] result in
                                do {
                                    let (status, _) = try result.get(); try requireSuccess(status)
                                    helper.expires = ProcessInfo.processInfo.systemUptime + 900
                                    verifyLaunch(generation: token, remaining: 5, completion: completion)
                                } catch { completion(.failure(error)) }
                            }
                        } catch { completion(.failure(error)) }
                    }
                } catch { completion(.failure(error)) }
            }
        } catch { completion(.failure(error)) }
    }

    private func verifyLaunch(generation token: UInt64, remaining: Int,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        request(URLRequest(url: url(port: 6770, path: helperStatusPath)), generation: token) { [self] result in
            if case .failure(let error) = result,
               (error as? URLError)?.code == .cannotConnectToHost, remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                    guard generation == token else { return }
                    verifyLaunch(generation: token, remaining: remaining - 1, completion: completion)
                }
                return
            }
            do {
                let (status, data) = try result.get(); try requireSuccess(status)
                _ = try decodeSnapshot(data)
                completion(.success(()))
            } catch {
                completion(.failure(RemotePlaySetupError("The uploaded helper did not authenticate after launch. Stop the old helper or wait for its 15-minute expiry before starting again.")))
            }
        }
    }

    deinit { task?.cancel() }
}
