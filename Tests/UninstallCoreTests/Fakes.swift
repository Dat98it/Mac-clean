import Foundation
@testable import UninstallCore

/// An in-memory file system. Nothing a test does with it reaches the disk.
final class FakeFileSystem: FileSystem, @unchecked Sendable {
    struct Node {
        var info: FileInfo
        var data = Data()
        var linkTarget: String?
    }

    private(set) var nodes: [String: Node] = [:]
    var denied: Set<String> = []
    private var nextInode: UInt64 = 100

    init() {
        addDir("/")
    }

    private func newInode() -> UInt64 {
        nextInode += 1
        return nextInode
    }

    /// Creates the folder and any missing parents.
    @discardableResult
    func addDir(_ path: String, modified: Date = .distantPast, owner: UInt32? = nil) -> FakeFileSystem {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            if nodes[current] == nil {
                nodes[current] = Node(info: FileInfo(type: .directory, inode: newInode(), allocatedSize: 0, modified: modified))
            }
        }
        if path == "/" { nodes["/"] = Node(info: FileInfo(type: .directory, inode: 2)) }
        nodes[path]?.info.modified = modified
        nodes[path]?.info.ownerID = owner
        return self
    }

    @discardableResult
    func addFile(_ path: String, size: UInt64 = 4096, privateSize: UInt64? = nil, data: Data = Data(),
                 modified: Date = .distantPast, inode: UInt64? = nil, linkCount: UInt64 = 1, owner: UInt32? = nil) -> FakeFileSystem {
        addDir((path as NSString).deletingLastPathComponent)
        nodes[path] = Node(info: FileInfo(type: .regular, inode: inode ?? newInode(), linkCount: linkCount, allocatedSize: size,
                                          privateSize: privateSize, modified: modified, ownerID: owner), data: data)
        return self
    }

    @discardableResult
    func addSymlink(_ path: String, to target: String) -> FakeFileSystem {
        addDir((path as NSString).deletingLastPathComponent)
        nodes[path] = Node(info: FileInfo(type: .symlink, inode: newInode(), allocatedSize: 0), linkTarget: target)
        return self
    }

    /// Moves a node and everything under it, keeping inodes (like `rename`).
    func move(_ from: String, to: String) throws {
        guard nodes[from] != nil else { throw FileSystemError.notFound(from) }
        guard nodes[to] == nil else { throw FileSystemError.other(to, "exists") }
        addDir((to as NSString).deletingLastPathComponent)
        for (path, node) in nodes where path == from || path.hasPrefix(from + "/") {
            nodes[path] = nil
            nodes[to + path.dropFirst(from.count)] = node
        }
    }

    func removeTree(_ path: String) {
        for key in nodes.keys where key == path || key.hasPrefix(path + "/") { nodes[key] = nil }
    }

    func replaceWithNewObject(_ path: String) {
        nodes[path]?.info.inode = newInode()
    }

    func exists(_ path: String) -> Bool { nodes[path] != nil }

    // MARK: FileSystem

    /// Like the kernel: symbolic links in the parent folders are followed, the last component is not.
    private func resolveParent(_ path: String) throws -> String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        let resolved = try canonicalPath(parent)
        return Paths.join(resolved, Paths.lastComponent(path))
    }

    func info(_ path: String) throws -> FileInfo {
        if denied.contains((path as NSString).deletingLastPathComponent) { throw FileSystemError.permissionDenied(path) }
        guard let node = nodes[try resolveParent(path)] else { throw FileSystemError.notFound(path) }
        return node.info
    }

    func contents(ofDirectory path: String) throws -> [String] {
        if denied.contains(path) { throw FileSystemError.permissionDenied(path) }
        let path = try canonicalPath(path)
        guard let node = nodes[path] else { throw FileSystemError.notFound(path) }
        guard node.info.type == .directory else { throw FileSystemError.other(path, "not a directory") }
        let prefix = path == "/" ? "/" : path + "/"
        return nodes.keys.filter { $0.hasPrefix(prefix) && $0.count > prefix.count && !$0.dropFirst(prefix.count).contains("/") }
            .map { String($0.dropFirst(prefix.count)) }
    }

    func readFile(_ path: String) throws -> Data {
        guard let node = nodes[path], node.info.type == .regular else { throw FileSystemError.notFound(path) }
        return node.data
    }

    func canonicalPath(_ path: String) throws -> String {
        var resolved = ""
        for part in path.split(separator: "/") {
            let next = resolved + "/" + part
            guard let node = nodes[next] else { throw FileSystemError.notFound(next) }
            if let target = node.linkTarget { resolved = try canonicalPath(target) } else { resolved = next }
        }
        return resolved.isEmpty ? "/" : resolved
    }
}

/// Moves into a fake Trash folder and remembers every call.
final class FakeTrasher: Trashing, @unchecked Sendable {
    let fs: FakeFileSystem
    let trashFolder: String
    var calls: [String] = []
    var failing: Set<String> = []

    init(fs: FakeFileSystem, trashFolder: String) {
        self.fs = fs
        self.trashFolder = trashFolder
        fs.addDir(trashFolder)
    }

    func trash(_ path: String) throws -> String {
        calls.append(path)
        if failing.contains(path) { throw FileSystemError.permissionDenied(path) }
        var destination = trashFolder + "/" + Paths.lastComponent(path)
        var n = 2
        while fs.exists(destination) {
            destination = trashFolder + "/" + Paths.lastComponent(path) + " \(n)"
            n += 1
        }
        try fs.move(path, to: destination)
        return destination
    }
}

final class FakeRemover: PermanentRemoving, @unchecked Sendable {
    let fs: FakeFileSystem
    var calls: [String] = []
    init(fs: FakeFileSystem) { self.fs = fs }
    func remove(_ path: String) throws {
        calls.append(path)
        fs.removeTree(path)
    }
}

final class FakeAdminRemover: AdminRemoving, @unchecked Sendable {
    let fs: FakeFileSystem
    var calls: [[String]] = []
    init(fs: FakeFileSystem) { self.fs = fs }
    func removeForGood(_ paths: [String]) -> [String: Result<String?, AdminError>] {
        calls.append(paths)
        for p in paths { fs.removeTree(p) }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, .success(nil)) })
    }
}

final class FakeAdmin: AdminActing, @unchecked Sendable {
    let fs: FakeFileSystem
    var batches: [[PlannedItem]] = []
    init(fs: FakeFileSystem) { self.fs = fs }
    func perform(_ items: [PlannedItem], trashFolder: String) -> [String: Result<String?, AdminError>] {
        batches.append(items)
        var results: [String: Result<String?, AdminError>] = [:]
        for item in items {
            switch item.target {
            case .receipt: results[item.displayPath] = .success(nil)
            case .path(let p, _, _, _):
                let destination = trashFolder + "/" + Paths.lastComponent(p) + " admin"
                do {
                    try fs.move(p, to: destination)
                    results[p] = .success(destination)
                } catch {
                    results[p] = .failure(AdminError("\(error)"))
                }
            }
        }
        return results
    }
}

final class LogCollector: @unchecked Sendable {
    var lines: [String] = []
    var log: ActionLog { ActionLog(append: { [self] in lines.append($0) }) }
}

enum Fixture {
    static let home = "/Users/tester"
    static var locations: [Location] { Location.standard(home: home) }
    static var appRoots: [String] { ["/Applications", home + "/Applications"] }

    static func policy(_ fs: FakeFileSystem, selfPath: String? = "/Applications/Mac Clean.app",
                       selfID: String? = "com.dat98it.MacClean") -> SafetyPolicy {
        SafetyPolicy(fileSystem: fs, home: home, dataRoots: locations.map(\.path), appRoots: appRoots,
                     selfBundlePath: selfPath, selfBundleID: selfID)
    }

    /// A file system with the standard Library folders.
    static func fileSystem() -> FakeFileSystem {
        let fs = FakeFileSystem()
        for location in locations { fs.addDir(location.path) }
        fs.addDir("/Applications").addDir(home + "/Documents").addDir(home + "/Desktop").addDir(home + "/Downloads")
        return fs
    }

    static func app(_ id: String, names: [String], path: String? = nil, exec: String? = nil, team: String? = nil,
                    groups: [String] = [], nested: [String] = []) -> AppIdentity {
        AppIdentity(bundleID: id, path: path ?? "/Applications/\(names[0]).app", names: names, executableName: exec,
                    teamID: team, appGroups: groups, nestedBundleIDs: nested)
    }

    static let old = Date(timeIntervalSince1970: 1_600_000_000)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
}
