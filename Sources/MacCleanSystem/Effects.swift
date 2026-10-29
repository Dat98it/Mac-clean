import AppKit
import Darwin
import Foundation
import MacCleanCore

// Adapted from App Clean's Effects.swift.

/// The real Trash, through Finder's own API: the item goes to the Trash of its own volume and can
/// be put back.
public struct MacTrasher: Trashing {
    public init() {}

    public func trash(_ path: String) throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return (resulting as URL?)?.path ?? ""
    }
}

/// Deletes one item for good. `PermanentDeleter` only calls this for paths directly inside a Trash folder.
public struct MacPermanentRemover: PermanentRemoving {
    public init() {}

    public func remove(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

/// For trying the app on a throwaway folder tree: each volume's "Trash" is a folder inside that
/// tree, so nothing reaches the real Trash. Used with `--sandbox <folder>`.
public struct FolderTrasher: Trashing {
    public var folderFor: @Sendable (String) -> String

    public init(folderFor: @escaping @Sendable (String) -> String) {
        self.folderFor = folderFor
    }

    public func trash(_ path: String) throws -> String {
        let folder = folderFor(path)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let name = Paths.lastComponent(path)
        var destination = folder + "/" + name
        var n = 2
        while FileManager.default.fileExists(atPath: destination) || (try? FileManager.default.destinationOfSymbolicLink(atPath: destination)) != nil {
            destination = folder + "/" + name + " \(n)"
            n += 1
        }
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }
}

/// Runs the administrator script through the standard macOS password dialog (`osascript ... with
/// administrator privileges`). Only that script runs as root; the app itself never does.
public struct AdministratorScriptRunner: AdminActing, AdminRemoving {
    public init() {}

    public func perform(_ items: [PlannedItem], trashFolder: String) -> [String: Result<String?, AdminError>] {
        let stamp = String(Int(Date().timeIntervalSince1970))
        return run(AdminScript.build(items, trashFolder: trashFolder, stamp: stamp), keys: items.map(\.path))
    }

    public func removeForGood(_ paths: [String]) -> [String: Result<String?, AdminError>] {
        run(AdminScript.buildRemoval(paths), keys: paths)
    }

    func run(_ script: String, keys: [String]) -> [String: Result<String?, AdminError>] {
        // The script travels as an AppleScript string literal: escape backslashes and quotes.
        let literal = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        func failAll(_ message: String) -> [String: Result<String?, AdminError>] {
            Dictionary(keys.map { ($0, .failure(AdminError(message))) }, uniquingKeysWith: { a, _ in a })
        }
        do { try process.run() } catch { return failAll("\(error)") }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus != 0 && output.isEmpty {
            // Most often: the user cancelled the password dialog (error -128).
            return failAll(errors.contains("-128") ? "cancelled" : errors.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // `do shell script` turns line feeds into carriage returns.
        return AdminScript.parse(output.replacingOccurrences(of: "\r", with: "\n"), keys: keys)
    }
}

/// Files held open by this user's processes, through libproc. Processes of other users (root
/// daemons) cannot be inspected; Finder's own move then reports "in use" if it matters.
public struct OpenFileChecker: OpenFileChecking {
    public var firmlinks: FirmlinkMap

    public init(firmlinks: FirmlinkMap) {
        self.firmlinks = firmlinks
    }

    public func openItems(under paths: [String]) -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for (file, process) in openFiles() {
            let shown = firmlinks.displayPath(file)
            for path in paths where result[path] == nil && (Paths.isWithin(shown, path) || Paths.isWithin(file, path)) {
                result[path] = process
            }
        }
        return result
    }

    /// Every open vnode path of every process this user may inspect, with the process name.
    func openFiles() -> [(String, String)] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(pidCount) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [(String, String)] = []
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdBytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride + 16)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
            guard used > 0 else { continue }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            let processName = String(cString: name)
            for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if !path.isEmpty { result.append((path, processName)) }
            }
        }
        return result
    }
}

public enum Permissions {
    /// Full Disk Access cannot be queried, so this opens a file only it unlocks: the system's
    /// permission database. Note: a process inherits the permissions of whatever launched it.
    /// Launched from a terminal or from Claude's shell, the app sees *their* access.
    public static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    @MainActor
    public static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// `UserDefaults` as a preference store.
public final class DefaultsStore: PreferenceStoring {
    let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    public func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// Settings kept in a property list file, for sandbox runs: nothing is written to the real
/// ~/Library/Preferences.
public final class FilePreferences: PreferenceStoring {
    let file: String
    private var values: [String: Any]

    public init(file: String) {
        self.file = file
        values = (NSDictionary(contentsOfFile: file) as? [String: Any]) ?? [:]
    }

    public func object(forKey key: String) -> Any? { values[key] }

    public func set(_ value: Any?, forKey key: String) {
        values[key] = value
        (values as NSDictionary).write(toFile: file, atomically: true)
    }
}
