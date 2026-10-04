// padd Start / Stop from the app: the same deploy flow and archive as `ps5mcp padd start|stop`.
//
// padd takes one client, and the CLI needs that slot (HELLO and auto-assign on start, SHUTDOWN on stop). So the
// app pauses its own link, runs the CLI once, and resumes. Nothing here retries or relaunches padd on its own.

import Foundation

final class PaddRunner {
    let config: Config
    weak var hub: Hub?
    private let lock = NSLock()
    private var running: String?
    private var last: [String: Any]?

    init(config: Config) { self.config = config }

    var json: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["running": running ?? NSNull(), "last": last ?? NSNull(), "available": !cli.isEmpty]
    }

    var busy: String? { lock.lock(); defer { lock.unlock() }; return running }

    /// `<cli> padd <action> --host H [--firmware F]`. The CLI is the project's own `.venv/bin/ps5mcp` (no resolver
    /// or network step, which hung under `uv run` when launched from the app), else `uv run --project <repo> ps5mcp`.
    var cli: [String] {
        if let cli = config.paddCLI { return [cli] }
        guard let repo = config.repo, !repo.isEmpty else { return [] }
        let venv = repo + "/.venv/bin/ps5mcp"
        if FileManager.default.isExecutableFile(atPath: venv) { return [venv] }
        guard let uv = config.uv, !uv.isEmpty else { return [] }
        return [uv, "run", "--project", repo, "ps5mcp"]
    }

    /// The environment for any `ps5mcp` run from the app.
    var cliEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PS5MCP_STATE"] = config.stateDir
        env["PS5MCP_IN_APP"] = "1"  // the CLI must not hand the job back to the app
        env["PATH"] = ([config.uv.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }, env["PATH"],
                        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"] as [String?]).compactMap { $0 }.joined(separator: ":")
        return env
    }

    func run(_ action: String, firmware: String?) throws -> [String: Any] {
        guard let hub else { throw BadInput("hub gone") }
        let base = cli
        guard !base.isEmpty else {
            throw ApiError(code: "padd_unavailable", message: "no repo/uv known to the app; rebuild it with make")
        }
        lock.lock()
        if let running {
            lock.unlock()
            throw ApiError(code: "padd_busy", message: "padd \(running) is already running")
        }
        running = action
        lock.unlock()
        hub.statusChanged()
        defer {
            lock.lock(); running = nil; lock.unlock()
            hub.controller.resume()
            hub.statusChanged()
        }

        hub.controller.pause()
        var args = Array(base.dropFirst()) + ["padd", action, "--host", hub.host]
        if action == "start" { args += ["--firmware", firmware ?? config.firmware] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: base[0])
        process.arguments = args
        process.environment = cliEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        say("padd \(action): \(([base[0]] + args).joined(separator: " "))")
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        try? text.write(toFile: config.stateDir + "/padd-\(action).log", atomically: true, encoding: .utf8)

        // padd_runner prints "<status>: results/<run-id>-padd" as its summary line.
        var result: [String: Any] = ["ok": process.terminationStatus == 0, "action": action,
                                     "exit": Int(process.terminationStatus),
                                     "output": text.split(separator: "\n").suffix(30).joined(separator: "\n")]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].hasSuffix(":"), parts[1].hasPrefix("results/") {
                result["status"] = String(parts[0].dropLast())
                result["run"] = String(parts[1])
            }
        }
        if process.terminationStatus != 0 && result["status"] == nil {
            hub.notice = "padd \(action) failed (exit \(process.terminationStatus)); see \(config.stateDir)/padd-\(action).log"
        } else if text.contains("auto-assign: done") {
            hub.notice = "padd started and the virtual pad answered \"Who's using this controller?\". If your "
                + "DualSense turned off, press its PS button and pick the same user; both controllers then work."
        } else if action == "start" && process.terminationStatus == 0 {
            hub.notice = "padd started."
        } else if action == "stop" {
            hub.notice = "padd \(result["status"] ?? "stopped") (\(result["run"] ?? "no run recorded"))."
        } else {
            hub.notice = "padd \(action) failed (exit \(process.terminationStatus)); see \(config.stateDir)/padd-\(action).log"
        }
        lock.lock(); last = result; lock.unlock()
        return result
    }
}
