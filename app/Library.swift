// Installed titles (for the launcher) and saved input recordings (the same files as `ps5mcp/recording.py`).

import AppKit
import Foundation

struct Title {
    let id: String
    let name: String
    var icon: NSImage?
}

/// Titles from PS5 Web File Manager's API on the console (port 8888): `/user/app` for the ids, and `param.json` and
/// `icon0.png` for names and icons: in `/user/appmeta/<id>/` for installed packages, else in
/// `/user/app/<id>/sce_sys/` (homebrew such as Payload Manager). Names and icons are cached in `<state>/titles/`, so
/// the list fills at once and only new titles, and titles still without a name, are fetched.
final class TitleLibrary {
    let host: String
    let dir: String
    private let session: URLSession

    init(host: String, stateDir: String) {
        self.host = host
        dir = stateDir + "/titles"
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    /// The titles from the last refresh, without contacting the console.
    func cached() -> [Title] {
        guard let data = FileManager.default.contents(atPath: dir + "/index.json"),
              let index = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return sorted(index.compactMap { entry in
            guard let id = entry["id"] else { return nil }
            return Title(id: id, name: entry["name"] ?? id, icon: NSImage(contentsOfFile: "\(dir)/\(id).png"))
        })
    }

    /// Lists `/user/app` and fetches what the cache lacks. Blocking; call it off the main thread.
    func refresh() throws -> [Title] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let known = Dictionary(cached().filter { $0.name != $0.id }.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        let listing = try api("/api/list", ["path": "/user/app"])
        let ids = (listing["entries"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        // One request at a time: Web File Manager runs one task at a time (docs/findings.md).
        let titles = try ids.map { try known[$0] ?? fetchTitle($0) }
        let index = titles.map { ["id": $0.id, "name": $0.name] }
        try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: dir + "/index.json"))
        return sorted(titles)
    }

    /// A title without metadata in either place keeps its id as its name. A network error ends the refresh
    /// instead, so the title is not cached without its name.
    private func fetchTitle(_ id: String) throws -> Title {
        let places = ["/user/appmeta/\(id)", "/user/app/\(id)/sce_sys"]
        var name = id
        for place in places {
            if let data = try missingIsNil({ try download(place + "/param.json") }),
               let param = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let found = titleName(param) {
                name = found
                break
            }
        }
        let iconPath = "\(dir)/\(id).png"
        for place in places {
            if let data = try missingIsNil({ try download(place + "/icon0.png") }), let png = thumbnail(data) {
                try? png.write(to: URL(fileURLWithPath: iconPath))
                break
            }
        }
        return Title(id: id, name: name, icon: NSImage(contentsOfFile: iconPath))
    }

    /// Web File Manager answers 404 or `ok: false` (BadInput here) for a file that is not there.
    private func missingIsNil(_ fetch: () throws -> Data) throws -> Data? {
        do { return try fetch() } catch is BadInput { return nil }
    }

    /// icon0.png is 512 px; the menu shows it at 16 pt.
    private func thumbnail(_ data: Data) -> Data? {
        guard let source = NSBitmapImageRep(data: data) else { return nil }
        let side = 64
        guard let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return small.representation(using: .png, properties: [:])
    }

    private func sorted(_ titles: [Title]) -> [Title] {
        titles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func titleName(_ param: [String: Any]) -> String? {
        guard let localized = param["localizedParameters"] as? [String: Any] else { return nil }
        let language = localized["defaultLanguage"] as? String ?? "en-US"
        for key in [language, "en-US"] {
            if let name = (localized[key] as? [String: Any])?["titleName"] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    private func api(_ path: String, _ query: [String: String]) throws -> [String: Any] {
        guard !host.isEmpty else { throw BadInput(missingHost) }
        var url = URLComponents(string: "http://\(host):8888\(path)")!
        url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let result = try json(try fetch(URLRequest(url: url.url!)))
        guard result["ok"] as? Bool == true else { throw BadInput("\(path): \(result["error"] ?? "failed")") }
        return result
    }

    /// Two steps, as `probe_runner.Console.download`: prepare a task for the path, then fetch it.
    private func download(_ path: String) throws -> Data {
        guard !host.isEmpty else { throw BadInput(missingHost) }
        var prepare = URLRequest(url: URL(string: "http://\(host):8888/api/download/prepare")!)
        prepare.httpMethod = "POST"
        prepare.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "paths", value: path)]
        prepare.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let task = try json(try fetch(prepare))
        guard task["ok"] as? Bool == true, let id = task["task_id"] as? Int else {
            throw BadInput("\(path): \(task["error"] ?? "not found")")
        }
        return try fetch(URLRequest(url: URL(string: "http://\(host):8888/api/download?id=\(id)")!))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BadInput("not a JSON object")
        }
        return object
    }

    private func fetch(_ request: URLRequest) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(BadInput("no response"))
        session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code == 404 {
                result = .failure(BadInput("\(request.url?.path ?? ""): not found"))  // a missing file
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                // 409 "another task is running": Web File Manager is busy with another client's task.
                result = .failure(URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: request.url as Any,
                                                                          NSLocalizedDescriptionKey: "Web File Manager answered HTTP \(code)"]))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}

// MARK: - recordings

/// Timeline of merged pad states, as `recording.Recorder`: `note` on every change, `steps` at the end.
final class InputRecorder {
    let started = uptimeSeconds()
    private let lock = NSLock()
    private var changes: [(at: Double, state: PadState)] = []

    init(current: PadState) { note(current, at: started) }

    func note(_ state: PadState, at: Double) {
        lock.lock(); defer { lock.unlock() }
        if changes.last?.state != state { changes.append((at, state)) }
    }

    func steps(end: Double = uptimeSeconds()) -> [[String: Any]] {
        lock.lock()
        let changes = self.changes
        lock.unlock()
        var steps: [[String: Any]] = []
        for (i, change) in changes.enumerated() {
            let next = i + 1 < changes.count ? changes[i + 1].at : end
            var remaining = Int(((next - change.at) * 1000).rounded(.toNearestOrEven))
            while remaining > 0 {  // sequence steps are limited to Recordings.maxStepMS each
                let chunk = min(remaining, Recordings.maxStepMS)
                steps.append(Recordings.step(change.state, chunk))
                remaining -= chunk
            }
        }
        while let first = steps.first, first.count == 1 { steps.removeFirst() }  // leading idle time
        if let last = steps.last, last.count == 1 { steps.removeLast() }
        return steps
    }
}

/// `<state>/recordings/<name>.json`, the format `recording.py` reads and writes.
enum Recordings {
    static let maxStepMS = 10_000
    static let maxSeconds = 300.0

    static func dir(_ stateDir: String) -> String { stateDir + "/recordings" }

    static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func list(_ stateDir: String) -> [(name: String, durationMS: Int)] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir(stateDir))) ?? []
        return files.filter { $0.hasSuffix(".json") }.sorted().compactMap { file in
            guard let data = FileManager.default.contents(atPath: dir(stateDir) + "/" + file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["name"] as? String else { return nil }
            return (name, object["duration_ms"] as? Int ?? 0)
        }
    }

    static func save(_ stateDir: String, name: String, steps: [[String: Any]], source: String) throws -> String {
        guard isValidName(name) else { throw BadInput("recording names use letters, digits, - and _ (max 64)") }
        try FileManager.default.createDirectory(atPath: dir(stateDir), withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let body: [String: Any] = ["name": name, "source": source, "recorded_at": stamp.string(from: Date()),
                                   "duration_ms": steps.reduce(0) { $0 + ($1["duration_ms"] as? Int ?? 0) },
                                   "steps": steps]
        let path = "\(dir(stateDir))/\(name).json"
        var data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    static func load(_ stateDir: String, name: String) throws -> [[String: Any]] {
        guard isValidName(name),
              let data = FileManager.default.contents(atPath: "\(dir(stateDir))/\(name).json"),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = object["steps"] as? [[String: Any]] else { throw BadInput("no recording named '\(name)'") }
        return steps
    }

    /// `recording.state_to_step`: only what differs from rest, sticks -1..1, triggers 0..1.
    static func step(_ state: PadState, _ durationMS: Int) -> [String: Any] {
        func round4(_ value: Double) -> Double { (value * 10_000).rounded(.toNearestOrEven) / 10_000 }
        var step: [String: Any] = ["duration_ms": durationMS]
        let names = buttonBits.filter { state.buttons & $0.bit != 0 }.map(\.name)
        if !names.isEmpty { step["buttons"] = names }
        for (key, value) in [("lx", state.lx), ("ly", state.ly), ("rx", state.rx), ("ry", state.ry)]
        where value != PadState.center {
            step[key] = round4((Double(value) - Double(PadState.center)) / 127.5)
        }
        for (key, value) in [("l2", state.l2), ("r2", state.r2)] where value != 0 {
            step[key] = round4(Double(value) / 255)
        }
        return step
    }

    /// `recording.step_to_state`.
    static func state(_ step: [String: Any]) throws -> PadState {
        func number(_ key: String) -> Double { (step[key] as? NSNumber)?.doubleValue ?? 0 }
        func stick(_ key: String) -> UInt8 {
            UInt8(max(0, min(255, (Double(PadState.center) + max(-1, min(1, number(key))) * 127.5).rounded(.toNearestOrEven))))
        }
        func trigger(_ key: String) -> UInt8 { UInt8((255 * max(0, min(1, number(key)))).rounded(.toNearestOrEven)) }
        var state = PadState()
        state.buttons = try buttonMask(step["buttons"] as? [String] ?? [])
        state.lx = stick("lx"); state.ly = stick("ly"); state.rx = stick("rx"); state.ry = stick("ry")
        state.l2 = trigger("l2"); state.r2 = trigger("r2")
        return state
    }
}
