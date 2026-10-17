import Foundation

final class SetupHTTPFixture: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))!
    static var requests: [URLRequest] = []
    static var stopped = 0
    static var delay: TimeInterval = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.handler(request)
        let deliver = { [self] in
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: deliver) }
        else { deliver() }
    }
    override func stopLoading() { Self.stopped += 1 }
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private func body(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
private func wait<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error> {
    var result: Result<T, Error>?
    operation { value in precondition(Thread.isMainThread); result = value }
    let deadline = Date(timeIntervalSinceNow: 3)
    while result == nil && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
    return result ?? .failure(NSError(domain: "fixture timeout", code: 1))
}
private func fails<T>(_ result: Result<T, Error>) -> Error {
    if case .failure(let error) = result { return error }
    fatalError("unexpected success")
}

@main struct SetupTests {
    static let account: [String: Any] = ["userId": 42, "name": "Offline User", "slot": 2,
        "accountIdB64": "AAAAAAAAAAA=", "activated": false, "signedIn": false,
        "foreground": true, "preparationVerified": false]
    static func document(helper: String = "ps5mcp-remoteplay-setup", version: Int = 1,
                         capabilities: [String] = RemotePlaySetupClient.requiredCapabilities) -> Data {
        json(["ok": true, "helper": helper, "version": version, "capabilities": capabilities,
              "firmware": "12.00", "accounts": [account]])
    }
    static func main() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SetupHTTPFixture.self]
        let session = URLSession(configuration: config)
        var writable = true
        var tokenCount = 0
        RemotePlaySetupClient.clearHelperSessionsForTesting()
        let initialToken = String(repeating: "a", count: 64)
        let deployedToken = String(repeating: "b", count: 64)
        let payload = Data([0x7f, 0x45, 0x4c, 0x46]) + RemotePlaySetupClient.tokenMarker + Data([0])
        let client = try RemotePlaySetupClient(host: "192.0.2.15", session: session,
            authorizeMutation: { if !writable { throw NSError(domain: "leased", code: 1) } },
            makeToken: { tokenCount += 1; return String(repeating: tokenCount == 1 ? "a" : "b", count: 64) })
        let selected = try JSONDecoder().decode(RemotePlaySetupAccount.self, from: json(account))
        SetupHTTPFixture.handler = { _ in (200, document()) }

        // Preparation must require both verified helper identity and explicit consent.
        _ = fails(wait { client.prepare(account: selected, confirmed: true, completion: $0) })
        precondition(SetupHTTPFixture.requests.isEmpty)
        let snapshot = try wait { client.inspect(completion: $0) }.get()
        precondition(snapshot.accounts[0].userId == 42)
        _ = fails(wait { client.prepare(account: selected, confirmed: false, completion: $0) })
        precondition(SetupHTTPFixture.requests.count == 1)
        writable = false
        _ = fails(wait { client.prepare(account: selected, confirmed: true, completion: $0) })
        precondition(SetupHTTPFixture.requests.count == 1)
        writable = true

        var prepared = account
        prepared["accountIdB64"] = "AQIDBAUGBwg="
        prepared["activated"] = true
        prepared["preparationVerified"] = true
        SetupHTTPFixture.handler = { request in
            precondition(request.url!.host == "192.0.2.15" && request.url!.port == 6770)
            precondition(request.url!.path == "/api/prepare" && request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "X-RemotePlay-Setup") == "1")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + initialToken)
            precondition(request.value(forHTTPHeaderField: "Origin") == nil)
            let text = String(data: body(request), encoding: .utf8)!
            precondition(text == "userId=42&slot=2&expectedAccountIdB64=AAAAAAAAAAA%3D")
            return (200, json(["ok": true, "code": "prepared", "message": "done", "partialWrites": false,
                "backupPath": "/data/backup.json", "account": prepared, "requiresUserReboot": false]))
        }
        let result = try wait { client.prepare(account: selected, confirmed: true, completion: $0) }.get()
        precondition(result.account.accountIdB64 == "AQIDBAUGBwg=")
        precondition(result.backupPath == "/data/backup.json")

        // All sixteen console slots are supported; slot zero is never a valid target.
        var boundary = account; boundary["slot"] = 16
        try JSONDecoder().decode(RemotePlaySetupAccount.self, from: json(boundary)).validate()
        boundary["slot"] = 0
        do {
            try JSONDecoder().decode(RemotePlaySetupAccount.self, from: json(boundary)).validate()
            fatalError("accepted slot zero")
        } catch { }

        // A verified, unchanged account needs no additional backup or persistent write.
        let existing = try JSONDecoder().decode(RemotePlaySetupAccount.self, from: json(prepared))
        SetupHTTPFixture.handler = { _ in (200, json(["ok": true, "helper": "ps5mcp-remoteplay-setup",
            "version": 1, "capabilities": RemotePlaySetupClient.requiredCapabilities,
            "firmware": "12.00", "accounts": [prepared]])) }
        _ = try wait { client.inspect(completion: $0) }.get()
        SetupHTTPFixture.handler = { _ in (200, json(["ok": true, "code": "already-prepared", "message": "ready",
            "partialWrites": false, "noOp": true, "backupPath": "", "account": prepared, "requiresUserReboot": false])) }
        let noOp = try wait { client.prepare(account: existing, confirmed: true, completion: $0) }.get()
        precondition(noOp.account == existing && noOp.backupPath.isEmpty)

        // A changed account ID in readback cannot replace an existing user's identity.
        SetupHTTPFixture.handler = { _ in (200, json(["ok": true, "helper": "ps5mcp-remoteplay-setup",
            "version": 1, "capabilities": RemotePlaySetupClient.requiredCapabilities,
            "firmware": "12.00", "accounts": [prepared]])) }
        _ = try wait { client.inspect(completion: $0) }.get()
        var changed = prepared; changed["accountIdB64"] = "CAcGBQQDAgE="
        SetupHTTPFixture.handler = { _ in (200, json(["ok": true, "code": "prepared", "message": "done",
            "partialWrites": false, "backupPath": "/data/backup.json", "account": changed, "requiresUserReboot": false])) }
        _ = fails(wait { client.prepare(account: existing, confirmed: true, completion: $0) })

        // An incompatible helper must discard earlier inspected state before any write.
        for data in [document(helper: "other"), document(version: 2), document(capabilities: [])] {
            SetupHTTPFixture.handler = { _ in (200, data) }
            _ = fails(wait { client.inspect(completion: $0) })
            let count = SetupHTTPFixture.requests.count
            _ = fails(wait { client.prepare(account: selected, confirmed: true, completion: $0) })
            precondition(SetupHTTPFixture.requests.count == count)
        }
        SetupHTTPFixture.handler = { _ in (200, document()) }
        _ = try wait { client.inspect(completion: $0) }.get()
        SetupHTTPFixture.handler = { _ in (409, json(["ok": false, "code": "changed", "message": "Readback failed",
            "partialWrites": true, "backupPath": "/data/original.json", "requiresUserReboot": false])) }
        let error = fails(wait { client.prepare(account: selected, confirmed: true, completion: $0) })
        precondition(error.localizedDescription.contains("/data/original.json"))
        precondition(error.localizedDescription.contains("changed"))
        let requestCount = SetupHTTPFixture.requests.count
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(SetupHTTPFixture.requests.count == requestCount, "must not retry uncertain writes")

        // Verified restoration remains a failed preparation and never retries automatically.
        SetupHTTPFixture.handler = { _ in (200, document()) }
        _ = try wait { client.inspect(completion: $0) }.get()
        SetupHTTPFixture.handler = { _ in (409, json(["ok": false, "code": "registry-write", "message": "Readback failed",
            "partialWrites": true, "restored": true, "backupPath": "/data/original.json", "requiresUserReboot": false])) }
        let rolledBack = fails(wait { client.prepare(account: selected, confirmed: true, completion: $0) })
        precondition(rolledBack.localizedDescription.contains("Writes were rolled back and verified"))
        precondition(!rolledBack.localizedDescription.contains("Some account values may have changed"))
        let countAfterRestore = SetupHTTPFixture.requests.count
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(SetupHTTPFixture.requests.count == countAfterRestore)

        // Cancellation suppresses all queued completions and invalidates inspected accounts.
        SetupHTTPFixture.handler = { _ in (200, document()) }
        var delivered = false
        client.inspect { _ in delivered = true }
        client.cancel()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(!delivered)
        _ = fails(wait { client.prepare(account: selected, confirmed: true, completion: $0) })

        // Closing during an accepted preparation suppresses UI callbacks but retains its request.
        SetupHTTPFixture.handler = { _ in (200, document()) }
        _ = try wait { client.inspect(completion: $0) }.get()
        SetupHTTPFixture.handler = { _ in (200, json(["ok": true, "partialWrites": false,
            "backupPath": "/data/backup.json", "account": prepared, "requiresUserReboot": false])) }
        SetupHTTPFixture.delay = 0.05
        let stoppedBefore = SetupHTTPFixture.stopped
        var preparationDelivered = false
        client.prepare(account: selected, confirmed: true) { _ in preparationDelivered = true }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        client.cancel()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        precondition(SetupHTTPFixture.stopped == stoppedBefore)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.09))
        precondition(!preparationDelivered)
        SetupHTTPFixture.delay = 0

        // The setup transport's installed delegate refuses redirect forwarding for both services.
        for port in [6770, 8084] {
            let original = URLRequest(url: URL(string: "http://192.0.2.15:\(port)/api/accounts")!)
            let task = session.dataTask(with: original)
            let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "http://192.0.2.99/collect"])!
            var called = false
            RemotePlaySetupRedirectGuard().urlSession(session, task: task,
                willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "http://192.0.2.99/collect")!)) {
                called = true; precondition($0 == nil)
            }
            precondition(called)
        }

        // Helper deployment uses the captured host, unique payload match, then encoded launch path.
        SetupHTTPFixture.requests = []
        var inspectedOld = false
        SetupHTTPFixture.handler = { request in
            precondition(request.url!.host == "192.0.2.15")
            switch request.url!.path {
            case "/api/accounts":
                precondition(request.url!.port == 6770)
                let expected = inspectedOld ? deployedToken : initialToken
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + expected)
                inspectedOld = true
                return (200, document())
            case "/api/shutdown":
                precondition(request.httpMethod == "POST")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + initialToken)
                return (200, json(["ok": true]))
            case "/manage:upload":
                precondition(request.url!.port == 8084 && request.value(forHTTPHeaderField: "Authorization") == nil)
                precondition(request.httpMethod == "POST" && request.url!.query == "filename=ps5mcp-remoteplay-setup.elf")
                precondition(body(request) == (try! RemotePlaySetupClient.personalizedPayload(payload, token: deployedToken)))
                precondition(body(request).range(of: RemotePlaySetupClient.tokenMarker) == nil)
                return (200, Data())
            case "/list_payloads": return (200, json(["payloads": ["/data/payloads/setup helper/ps5mcp-remoteplay-setup.elf"]]))
            case "/loadpayload:/data/payloads/setup helper/ps5mcp-remoteplay-setup.elf": return (200, Data())
            default: fatalError("unexpected deployment route")
            }
        }
        _ = try wait { client.startHelper(payload: payload, completion: $0) }.get()
        precondition(SetupHTTPFixture.requests.count == 6)

        // Reopening the wizard reuses only the same host's in-memory helper session.
        let reopened = try RemotePlaySetupClient(host: "192.0.2.15", session: session)
        SetupHTTPFixture.handler = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + deployedToken)
            return (200, document())
        }
        _ = try wait { reopened.inspect(completion: $0) }.get()
        let otherHost = try RemotePlaySetupClient(host: "192.0.2.16", session: session,
            makeToken: { String(repeating: "c", count: 64) })
        SetupHTTPFixture.handler = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "c", count: 64))
            return (200, document())
        }
        _ = try wait { otherHost.inspect(completion: $0) }.get()

        // An old unauthenticated session is never silently overwritten or reported started.
        SetupHTTPFixture.requests = []
        SetupHTTPFixture.handler = { _ in (401, json(["ok": false, "code": "unauthorized"])) }
        let conflict = fails(wait { client.startHelper(payload: payload, completion: $0) })
        precondition(SetupHTTPFixture.requests.count == 1 && conflict.localizedDescription.contains("15 minutes"))
        precondition(!conflict.localizedDescription.contains(initialToken) && !conflict.localizedDescription.contains(deployedToken))

        // Missing, duplicate, or malformed personalization markers never reach the console.
        for badPayload in [Data(), Data([1, 2, 3]), payload + RemotePlaySetupClient.tokenMarker] {
            SetupHTTPFixture.requests = []
            _ = fails(wait { client.startHelper(payload: badPayload, completion: $0) })
            precondition(SetupHTTPFixture.requests.isEmpty)
        }
        let a = try RemotePlaySetupClient.randomToken(), b = try RemotePlaySetupClient.randomToken()
        precondition(a.count == 64 && b.count == 64 && a != b)
        SetupHTTPFixture.requests = []
        writable = false
        _ = fails(wait { client.startHelper(payload: Data([1]), completion: $0) })
        precondition(SetupHTTPFixture.requests.isEmpty)
        for bad in ["", "host/path", "http://host", "host?query"] {
            do { _ = try RemotePlaySetupClient(host: bad); fatalError("accepted unsafe host") } catch { }
        }
        writable = true
        let requestID = String(repeating: "c", count: 32)
        let buildID = String(repeating: "d", count: 64)
        var report: [String: Any] = ["ok": 1, "code": "patched", "mode": "apply",
            "requestId": requestID, "buildId": buildID, "changed": 1, "already": 0]
        SetupHTTPFixture.handler = { request in
            precondition(request.url!.path == "/api/admission")
            precondition(request.value(forHTTPHeaderField: "Authorization") != nil)
            precondition(request.value(forHTTPHeaderField: "X-RemotePlay-Setup") == "1")
            precondition(String(data: body(request), encoding: .utf8) == "mode=apply&requestId=" + requestID)
            return (200, json(report))
        }
        let admitted = try wait { client.admission(mode: .apply, requestID: requestID, expectedBuildID: buildID, completion: $0) }.get()
        precondition(admitted.code == "patched")
        for (key, invalid) in [("requestId", "old"), ("buildId", "old"), ("mode", "check")] {
            let saved = report[key]; report[key] = invalid
            _ = fails(wait { client.admission(mode: .apply, requestID: requestID, expectedBuildID: buildID, completion: $0) })
            report[key] = saved
        }
        report["ok"] = 0; report["code"] = "context-mismatch"
        let refused = fails(wait { client.admission(mode: .apply, requestID: requestID, expectedBuildID: buildID, completion: $0) })
        precondition(refused.localizedDescription.contains("supported"))
        report["code"] = "write-failed"; report["rollbackAttempted"] = 1; report["rollbackVerified"] = 0
        let partial = fails(wait { client.admission(mode: .apply, requestID: requestID, expectedBuildID: buildID, completion: $0) })
        precondition(partial.localizedDescription.contains("could not be undone") && partial.localizedDescription.contains("Restart the PS5"))
        report["rollbackVerified"] = 1
        let undone = fails(wait { client.admission(mode: .apply, requestID: requestID, expectedBuildID: buildID, completion: $0) })
        precondition(undone.localizedDescription.contains("fix failed"))
        report["code"] = "context-mismatch"; report["rollbackAttempted"] = nil; report["rollbackVerified"] = nil
        let before = SetupHTTPFixture.requests.count
        writable = false
        _ = fails(wait { client.admission(mode: .apply, requestID: requestID, expectedBuildID: buildID, completion: $0) })
        precondition(SetupHTTPFixture.requests.count == before)
        writable = true
        SetupHTTPFixture.requests = []
        SetupHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, document())
            case "/api/shutdown", "/manage:upload": return (200, json(["ok": true]))
            case "/list_payloads": return (200, json(["payloads": ["/data/ps5mcp-remoteplay-setup.elf"]]))
            case "/loadpayload:/data/ps5mcp-remoteplay-setup.elf": return (200, Data())
            default: fatalError("admission startup inspected account data")
            }
        }
        _ = try wait { client.startHelper(payload: payload, inspectAccounts: false, completion: $0) }.get()
        precondition(SetupHTTPFixture.requests.count == 6)

        // Automatic admission redeploys the helper from its own client: an open wizard follows the new token
        // instead of presenting the replaced one and reporting an expired session.
        let admissionToken = String(repeating: "e", count: 64)
        let admissionClient = try RemotePlaySetupClient(host: "192.0.2.15", session: session, makeToken: { admissionToken })
        _ = try wait { admissionClient.startHelper(payload: payload, inspectAccounts: false, completion: $0) }.get()
        SetupHTTPFixture.handler = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + admissionToken)
            return (200, document())
        }
        _ = try wait { reopened.inspect(completion: $0) }.get()
        _ = try wait { client.inspect(completion: $0) }.get()
        print("setup checks passed")
    }
}
