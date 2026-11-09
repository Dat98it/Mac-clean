import UninstallCore
import AppKit
import Foundation

/// Collects every installed app from all sources. Read-only: runs `lsregister -dump` and `pkgutil`
/// queries, which only read their databases.
public enum InstalledAppSources {
    public static func appFolders(home: String) -> [String] {
        var folders = ["/Applications", home + "/Applications", "/System/Applications", "/System/Library/CoreServices",
                       "/Applications/Setapp", "/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
        // Other mounted disks: their Applications folder and their top level.
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for volume in volumes {
            let path = "/Volumes/" + volume
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { continue } // the boot disk link
            folders += [path + "/Applications", path]
        }
        return folders
    }

    /// `.app` bundles up to `depth` folders below each root (not inside other apps).
    public static func findApps(in roots: [String], depth: Int = 3) -> [String] {
        var found: [String] = []
        func walk(_ dir: String, _ level: Int) {
            guard level <= depth, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = dir + "/" + name
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { continue }
                if name.hasSuffix(".app") { found.append(path) } else { walk(path, level + 1) }
            }
        }
        for root in roots { walk(root, 1) }
        return found
    }

    /// Identifier → paths from the LaunchServices database, which also remembers apps on disks
    /// that are not connected right now.
    public static func launchServicesRecords() -> (ids: [String: [String]], names: Set<String>) {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard let output = run(tool, ["-dump"]) else { return ([:], []) }
        var records: [String: [String]] = [:]
        var names = Set<String>()
        var path: String?
        var id: String?
        var name: String?
        func flush() {
            if let path, path.hasSuffix(".app") || path.contains(".app/") {
                if let id { records[id.lowercased(), default: []].append(path) }
                if let name, !name.isEmpty { names.insert(name) }
            }
            path = nil
            id = nil
            name = nil
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("--------") { flush(); continue }
            if line.hasPrefix("path:") {
                var value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let paren = value.range(of: " (0x", options: .backwards) { value = String(value[..<paren.lowerBound]) }
                path = value
            } else if line.hasPrefix("identifier:") {
                id = line.dropFirst(11).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("name:") {
                name = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return (records, names)
    }

    public static func packageIDs() -> [String] {
        (run("/usr/sbin/pkgutil", ["--pkgs"]) ?? "").split(separator: "\n").map(String.init)
    }

    /// The package's files, relative to its install location's volume.
    public static func packageFiles(_ id: String) -> [String] {
        let info = run("/usr/sbin/pkgutil", ["--pkg-info", id]) ?? ""
        let location = info.split(separator: "\n").first { $0.hasPrefix("location:") }
            .map { $0.dropFirst(9).trimmingCharacters(in: .whitespaces) } ?? ""
        let files = (run("/usr/sbin/pkgutil", ["--files", id]) ?? "").split(separator: "\n").map(String.init)
        return files.map { location.isEmpty ? $0 : location + "/" + $0 }
    }

    /// A package counts as still installed when some of its files (not folders) are still on disk.
    public static func isPackageLive(files: [String]) -> Bool {
        var checked = 0
        for file in files {
            var isDir: ObjCBool = false
            let path = "/" + file
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { checked += 1; if checked > 200 { break }; continue }
            if !isDir.boolValue { return true }
        }
        return false
    }

    /// Executables on the usual PATH folders, plus Homebrew formula names.
    public static func commandLineTools(home: String) -> Set<String> {
        let folders = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/opt", "/usr/local/opt",
                       "/opt/homebrew/Cellar", "/usr/local/Cellar", home + "/.local/bin", home + "/bin", home + "/.cargo/bin"]
        var names = Set<String>()
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                // `mysql@9.5` → `mysql`
                names.insert(String(name.split(separator: "@").first ?? Substring(name)).lowercased())
            }
        }
        return names
    }

    public static func runningBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }

    static func run(_ tool: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
