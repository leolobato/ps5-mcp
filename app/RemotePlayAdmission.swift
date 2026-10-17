// Verified, cancelable per-boot compatibility operation. Confined to the main thread.
import Foundation

enum RemotePlayAdmissionMode: String, Decodable { case check, apply, restore }
struct RemotePlayAdmissionReport: Decodable {
    let ok: Int
    let code: String
    let mode: RemotePlayAdmissionMode
    let requestId: String
    let buildId: String
    let changed: Int
    let already: Int
    let rollbackAttempted: Int?
    let rollbackVerified: Int?

    func validate(mode expectedMode: RemotePlayAdmissionMode, requestID: String, buildID: String) throws {
        guard mode == expectedMode, requestId == requestID, buildId == buildID else {
            throw RemotePlaySetupError("The Remote Play fix response could not be verified. Reconnect to check again.")
        }
        guard ok == 1 else {
            // A failed write that could not be undone leaves a partial patch, which later attempts refuse as
            // unsupported: only a console restart clears it.
            if rollbackAttempted == 1 && rollbackVerified != 1 {
                throw RemotePlaySetupError("The Remote Play fix was only partly applied and could not be undone. Restart the PS5, reload Payload Manager, then reconnect.")
            }
            switch code {
            case "context-mismatch", "unknown", "unsupported-firmware":
                throw RemotePlaySetupError("This console is not supported by the bundled Remote Play fix. No further automatic attempt will be made.")
            case "no-daemon":
                throw RemotePlaySetupError("Remote Play is not running on the PS5. Enable it in the PS5 settings, then reconnect.")
            default:
                throw RemotePlaySetupError("The Remote Play fix failed. Check the console before reconnecting.")
            }
        }
        let accepted = expectedMode == .apply ? ["patched", "no-op"] : expectedMode == .restore ? ["restored", "no-op"] : ["stock", "patched"]
        guard accepted.contains(code) else { throw RemotePlaySetupError("The Remote Play fix returned an unexpected result.") }
    }
}

protocol RemotePlayAdmissionServicing: AnyObject {
    func apply(host: String, completion: @escaping (Result<Void, Error>) -> Void)
    func cancel()
}

final class RemotePlayAdmission: RemotePlayAdmissionServicing {
    static let sessionRequestUnknownReason = 2
    private let authorizeMutation: () throws -> Void
    private var client: RemotePlaySetupClient?
    private var generation: UInt64 = 0
    private var deadline: DispatchWorkItem?

    init(authorizeMutation: @escaping () throws -> Void = {}) { self.authorizeMutation = authorizeMutation }

    func cancel() {
        precondition(Thread.isMainThread)
        generation &+= 1
        deadline?.cancel(); deadline = nil
        client?.cancel(); client = nil
    }

    func apply(host: String, completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        let token = generation
        func finish(_ result: Result<Void, Error>) {
            guard self.generation == token else { return }
            self.cancel()
            completion(result)
        }
        do {
            try authorizeMutation()
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("remoteplay") else {
                throw RemotePlaySetupError("The bundled Remote Play helper is missing. Rebuild the app.")
            }
            let payload = try Data(contentsOf: root.appendingPathComponent("remoteplay-setup.elf"))
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("remoteplay-setup-report.json"))) as? [String: Any]
            guard let buildID = metadata?["build_id"] as? String, buildID.count == 64 else {
                throw RemotePlaySetupError("The bundled Remote Play helper has no valid build identity. Rebuild the app.")
            }
            let client = try RemotePlaySetupClient(host: host, authorizeMutation: authorizeMutation)
            self.client = client
            let timeout = DispatchWorkItem { [weak self] in
                guard self?.generation == token else { return }
                finish(.failure(RemotePlaySetupError("Remote Play preparation timed out. Check Payload Manager on the PS5, then reconnect. The console operation may have completed.")))
            }
            deadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
            client.startHelper(payload: payload, inspectAccounts: false) { result in
                guard self.generation == token else { return }
                switch result {
                case .failure(let error): finish(.failure(error))
                case .success:
                    client.admission(mode: .apply, requestID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), expectedBuildID: buildID) { result in
                        finish(result.map { _ in () })
                    }
                }
            }
        } catch { finish(.failure(error)) }
    }
}
