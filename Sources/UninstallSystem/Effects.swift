import UninstallCore
import AppKit
import Foundation

/// The real Trash, through Finder's own API: the item can be put back from the Trash.
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

/// For trying the app on a throwaway folder tree: "Trash" is a folder inside that tree, so nothing
/// reaches the real Trash. Used with `--sandbox <folder>`.
public struct FolderTrasher: Trashing {
    public var folder: String

    public init(folder: String) {
        self.folder = folder
    }

    public func trash(_ path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
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
        return run(AdminScript.build(items, trashFolder: trashFolder, stamp: stamp), keys: items.map(\.displayPath))
    }

    public func removeForGood(_ paths: [String]) -> [String: Result<String?, AdminError>] {
        run(AdminScript.buildRemoval(paths), keys: paths)
    }

    /// Runs one script as root through the standard password dialog, and matches its output to `keys`.
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

/// `launchctl bootout gui/<uid> <plist>` for user launch agents, so they stop before their file goes.
public struct LaunchctlUnloader: LaunchAgentUnloading {
    public init() {}

    public func unload(plist path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

public struct RunningApps: RunningAppChecking {
    public init() {}

    public func running(among bundleIDs: [String]) -> [String] {
        let wanted = Set(bundleIDs.map { $0.lowercased() })
        return NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { wanted.contains($0.lowercased()) }
    }

    /// Asks the apps to quit, like choosing Quit from their menu (they may ask to save).
    @MainActor
    public static func requestQuit(_ bundleIDs: [String]) {
        let wanted = Set(bundleIDs.map { $0.lowercased() })
        for app in NSWorkspace.shared.runningApplications where wanted.contains(app.bundleIdentifier?.lowercased() ?? "") {
            app.terminate()
        }
    }
}

public enum Permissions {
    /// Full Disk Access cannot be queried, so this opens a file only it unlocks: the system's
    /// permission database (the usual test; folders in ~/Library may be opened by narrower permissions).
    ///
    /// Note: a process inherits the permissions of whatever launched it (its "responsible"
    /// process). Launched from a terminal or from Claude's shell, the app sees *their* access.
    public static func hasFullDiskAccess(home: String) -> Bool {
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
