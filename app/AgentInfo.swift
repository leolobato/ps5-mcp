// Who is behind an API connection: the client process (usually an MCP server) and the agent that started it, for
// the window's claim details. Local processes of the same user only; anything unreadable is left out.

import Darwin
import Foundation

struct ProcessDetails {
    let pid: pid_t
    let name: String
    let cwd: String?
    let arguments: [String]
    let parent: pid_t?

    init?(pid: pid_t) {
        var info = proc_bsdinfo()
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else {
            return nil
        }
        self.pid = pid
        parent = info.pbi_ppid > 1 ? pid_t(info.pbi_ppid) : nil
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let named = proc_pidpath(pid, &path, UInt32(path.count)) > 0
        name = named ? (String(cString: path) as NSString).lastPathComponent
            : withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var vnode = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        } else {
            cwd = nil
        }
        arguments = Self.arguments(pid)
    }

    /// KERN_PROCARGS2: argc, the executable path, padding, then argv.
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }  // executable path
        while index < size && buffer[index] == 0 { index += 1 }  // padding
        var out: [String] = []
        while out.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            out.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return out
    }

    /// One line per field; the command line is shortened (agents put their whole prompt there).
    func describe(_ title: String, limit: Int = 600) -> String {
        var lines = ["\(title): \(name) (pid \(pid))"]
        if let cwd { lines.append("  folder: \(cwd)") }
        if let index = arguments.firstIndex(of: "--session-id"), index + 1 < arguments.count {
            lines.append("  session: \(arguments[index + 1])")
        }
        let command = arguments.dropFirst().joined(separator: " ")
        if !command.isEmpty {
            lines.append("  command: " + (command.count > limit ? command.prefix(limit) + "…" : command))
        }
        return lines.joined(separator: "\n")
    }
}

/// Launchers between an agent and its MCP server.
private let wrappers: Set<String> = ["uv", "uvx", "python", "python3", "Python", "sh", "zsh", "bash", "node", "env"]

/// The client process of `pid` and the first process above it that is not a launcher (the agent).
func agentDescription(pid: pid_t?) -> String {
    guard let pid, let client = ProcessDetails(pid: pid) else { return "process: unknown" }
    var text = client.describe("client process")
    var next = client.parent
    for _ in 0..<5 {
        guard let current = next, let process = ProcessDetails(pid: current) else { break }
        if !wrappers.contains(process.name) || process.parent == nil {
            text += "\n" + process.describe("agent")
            break
        }
        next = process.parent
    }
    return text
}
