// PS5 MCP: the macOS hub for capture, input, and the local API.
//
// - Owns the HDMI capture card: preview-layer window, direct audio, <state>/latest.jpg.
// - Owns the only padd connection (TCP 9305); keyboard and every API client feed one merged pad state.
// - Local API on <state>/capture.sock (docs/app-api.md); the MCP server is a thin client of it.
//
// Usage: PS5 [--state-dir DIR] [--video NAME|file:PATH|synthetic] [--audio NAME|none] [--headless]
//            [--host H] [--port N] [--no-auto-assign] [--padd-cli EXE] [--snapshot-fps N]
//        PS5 --dialog-score IMAGE   (prints the assignment-dialog match score and exits)

import AppKit
import Darwin

struct Config {
    var stateDir = ProcessInfo.processInfo.environment["PS5MCP_STATE"] ?? NSHomeDirectory() + "/.local/state/ps5-mcp"
    var video = "eEver USB Video Device"
    var audio: String? = "eEver USB Audio Device"
    var headless = false
    var snapshotFPS = 5.0
    var host = ProcessInfo.processInfo.environment["PS5_HOST"] ?? ""  // no default: see missingHost
    var port = PMCP.port
    var firmware = "13.60"
    var homeMethod = ProcessInfo.processInfo.environment["PS5MCP_HOME_METHOD"] ?? "suspend"
    var autoAssign = ProcessInfo.processInfo.environment["PS5MCP_AUTO_ASSIGN"] != "0"
    /// Baked into Info.plist by the Makefile: the repo (for the padd CLI and its archive) and uv.
    var repo = Bundle.main.object(forInfoDictionaryKey: "PS5MCPRepo") as? String
    var uv = Bundle.main.object(forInfoDictionaryKey: "PS5MCPUV") as? String
    var paddCLI: String?
    var templatePath = ""
    var dialogScore: String?

    init(_ args: [String]) {
        var i = 1
        while i < args.count {
            let value = i + 1 < args.count ? args[i + 1] : ""
            switch args[i] {
            case "--state-dir": stateDir = value; i += 1
            case "--video": video = value; i += 1
            case "--audio": audio = value == "none" ? nil : value; i += 1
            case "--snapshot-fps": snapshotFPS = Double(value) ?? 5; i += 1
            case "--host": host = value; i += 1
            case "--port": port = UInt16(value) ?? PMCP.port; i += 1
            case "--firmware": firmware = value; i += 1
            case "--repo": repo = value; i += 1
            case "--padd-cli": paddCLI = value; i += 1
            case "--dialog-score": dialogScore = value; i += 1
            case "--headless": headless = true
            case "--no-auto-assign": autoAssign = false
            default: break
            }
            i += 1
        }
        templatePath = Bundle.main.path(forResource: "assign-dialog", ofType: "png")
            ?? (repo ?? ".") + "/src/ps5mcp/assets/assign-dialog.png"
    }
}

let config = Config(CommandLine.arguments)
signal(SIGPIPE, SIG_IGN)

if let path = config.dialogScore {
    do {
        let assigner = try Assigner(templatePath: config.templatePath)
        guard let image = loadImage(path) else { throw BadInput("cannot read \(path)") }
        print(String(format: "%.6f", assigner.score(render(image))))
        exit(0)
    } catch {
        say("\(error)")
        exit(1)
    }
}

try? FileManager.default.createDirectory(atPath: config.stateDir, withIntermediateDirectories: true)
// No window restoration: after a crash it would block every launch (headless too) on a "reopen windows?" alert.
UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
let hub = Hub(config: config)
let app = NSApplication.shared
let delegate = AppDelegate(hub: hub)
app.delegate = delegate
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { hub.quit() }
    source.resume()
    signalSources.append(source)
}
app.run()
