import Foundation
@testable import MacCleanCore

/// An in-memory file system, also usable as a directory reader. Nothing a test does with it reaches
/// the disk. Adapted from App Clean's FakeFileSystem: like `lstat`, symbolic links in parent folders
/// are followed and the last component is not. Do not simplify that: symbolic link tests rely on it.
final class FakeFileSystem: FileSystem, DirectoryReading, @unchecked Sendable {
    struct Node {
        var info: FileInfo
        var entry: DirectoryEntry
        var linkTarget: String?
    }

    private(set) var nodes: [String: Node] = [:]
    /// Folders that cannot be listed (and whose children cannot be stat'ed).
    var denied: Set<String> = []
    /// Mount point → device. Everything below a mount point is on that device; "/" is device 1.
    var devices: [String: UInt64] = ["/": 1]
    /// Firmlinks: "/Users" is "/System/Volumes/Data/Users". Followed, but never shown by `canonicalPath`.
    var firmlinks: [String: String] = [:]
    /// Listing one of these throws "volume gone" (an unplugged disk).
    var gone: Set<String> = []
    /// Called before each listing (to cancel a scan midway, for example).
    var onList: ((String) -> Void)?
    private var nextInode: UInt64 = 100
    private let lock = NSLock()

    init() {
        addDir("/")
    }

    private func newInode() -> UInt64 {
        nextInode += 1
        return nextInode
    }

    func device(of path: String) -> UInt64 {
        devices.filter { Paths.isWithin(path, $0.key) }.max { $0.key.count < $1.key.count }?.value ?? 1
    }

    func mount(_ mountPoint: String, device: UInt64) {
        devices[mountPoint] = device
        addDir(mountPoint)
        for (path, node) in nodes where Paths.isWithin(path, mountPoint) {
            var n = node
            n.info.device = device
            n.entry.realDevice = device
            nodes[path] = n
        }
    }

    private func put(_ path: String, _ info: FileInfo, entry: DirectoryEntry, link: String? = nil) {
        var info = info
        var entry = entry
        info.device = device(of: path)
        entry.realDevice = info.device
        entry.fileID = info.inode
        nodes[path] = Node(info: info, entry: entry, linkTarget: link)
    }

    /// Creates the folder and any missing parents.
    @discardableResult
    func addDir(_ path: String, modified: Date = Date(timeIntervalSince1970: 1_000_000), owner: UInt32? = 501) -> FakeFileSystem {
        let path = resolveFirmlink(path)
        var current = ""
        let parts = path.split(separator: "/")
        if parts.isEmpty, nodes["/"] == nil {
            put("/", FileInfo(type: .directory, inode: 2), entry: DirectoryEntry(name: "/", type: .directory))
        }
        for part in parts {
            current += "/" + part
            if nodes[current] == nil {
                put(current, FileInfo(type: .directory, inode: newInode(), modified: modified, ownerID: owner),
                    entry: DirectoryEntry(name: String(part), type: .directory, birth: 1000, modified: Int64(modified.timeIntervalSince1970)))
            }
        }
        return self
    }

    @discardableResult
    func addFile(_ path: String, size: UInt64 = 4096, allocated: UInt64? = nil, modified: Date = Date(timeIntervalSince1970: 1_000_000),
                 birth: Int64? = 1000, inode: UInt64? = nil, linkCount: UInt32 = 1, owner: UInt32? = 501, dataless: Bool = false,
                 clone: (privateSize: UInt64, id: UInt64)? = nil) -> FakeFileSystem {
        let path = resolveFirmlink(path)
        addDir(Paths.parent(path))
        let alloc = allocated ?? (dataless ? 0 : size)
        let ino = inode ?? newInode()
        put(path, FileInfo(type: .regular, inode: ino, linkCount: UInt64(linkCount), size: size, allocatedSize: alloc, modified: modified, ownerID: owner),
            entry: DirectoryEntry(name: Paths.lastComponent(path), type: .regular, linkCount: linkCount, logicalSize: size,
                                  allocatedSize: alloc, birth: birth, modified: Int64(modified.timeIntervalSince1970), isDataless: dataless,
                                  mayShareBlocks: clone != nil, privateSize: clone?.privateSize, cloneID: clone?.id))
        return self
    }

    @discardableResult
    func addSymlink(_ path: String, to target: String) -> FakeFileSystem {
        let path = resolveFirmlink(path)
        addDir(Paths.parent(path))
        put(path, FileInfo(type: .symlink, inode: newInode(), ownerID: 501), entry: DirectoryEntry(name: Paths.lastComponent(path), type: .symlink),
            link: target)
        return self
    }

    /// Moves a node and everything under it, keeping inodes (like `rename`).
    func move(_ from: String, to: String) throws {
        let from = resolveFirmlink(from)
        let to = resolveFirmlink(to)
        guard nodes[from] != nil else { throw FileSystemError.notFound(from) }
        guard nodes[to] == nil else { throw FileSystemError.other(to, "exists") }
        addDir(Paths.parent(to))
        for (path, node) in nodes where Paths.isWithin(path, from) {
            nodes[path] = nil
            var n = node
            if path == from { n.entry.name = Paths.lastComponent(to) }
            nodes[to + path.dropFirst(from.count)] = n
        }
    }

    func removeTree(_ path: String) {
        let path = resolveFirmlink(path)
        for key in nodes.keys where Paths.isWithin(key, path) { nodes[key] = nil }
    }

    func replaceWithNewObject(_ path: String) {
        nodes[resolveFirmlink(path)]?.info.inode = newInode()
    }

    func touch(_ path: String, size: UInt64? = nil, modified: Date? = nil) {
        let p = resolveFirmlink(path)
        if let size { nodes[p]?.info.size = size }
        if let modified { nodes[p]?.info.modified = modified }
    }

    func has(_ path: String) -> Bool { nodes[resolveFirmlink(path)] != nil }

    func resolveFirmlink(_ path: String) -> String {
        for (link, target) in firmlinks where Paths.isWithin(path, link) {
            return target + path.dropFirst(link.count)
        }
        return path
    }

    // MARK: FileSystem

    /// Symbolic links in the parent folders are followed, the last component is not.
    private func resolveParent(_ path: String) throws -> String {
        guard path != "/" else { return "/" }
        let resolved = try canonicalPath(Paths.parent(path))
        return resolveFirmlink(Paths.join(resolved, Paths.lastComponent(path)))
    }

    func info(_ path: String) throws -> FileInfo {
        if denied.contains(Paths.parent(path)) { throw FileSystemError.permissionDenied(path) }
        guard let node = nodes[try resolveParent(path)] else { throw FileSystemError.notFound(path) }
        return node.info
    }

    func canonicalPath(_ path: String) throws -> String {
        var resolved = ""
        for part in path.split(separator: "/") {
            let next = resolved + "/" + part
            guard let node = nodes[resolveFirmlink(next)] else { throw FileSystemError.notFound(next) }
            if let target = node.linkTarget { resolved = try canonicalPath(target) } else { resolved = next }
        }
        return resolved.isEmpty ? "/" : resolved
    }

    // MARK: DirectoryReading

    func describe(_ path: String) throws -> DirectoryEntry {
        if gone.contains(path) { throw FileSystemError.volumeGone(path) }
        guard let node = nodes[resolveFirmlink(path)] else { throw FileSystemError.notFound(path) }
        return node.entry
    }

    func entries(of path: String) throws -> [DirectoryEntry] {
        onList?(path)
        lock.lock(); defer { lock.unlock() }
        if gone.contains(where: { Paths.isWithin(path, $0) }) { throw FileSystemError.volumeGone(path) }
        if denied.contains(path) { throw FileSystemError.permissionDenied(path) }
        // Follows a link given as the folder, like a naive reader would: the scanner must never ask.
        let path = (try? canonicalPath(path)).map(resolveFirmlink) ?? resolveFirmlink(path)
        guard let node = nodes[path], node.info.type == .directory else { throw FileSystemError.notFound(path) }
        let prefix = path == "/" ? "/" : path + "/"
        return nodes.filter { $0.key.hasPrefix(prefix) && $0.key.count > prefix.count && !$0.key.dropFirst(prefix.count).contains("/") }
            .sorted { $0.key < $1.key }
            .map { key, node in
                var e = node.entry
                e.isMountPoint = devices[key] != nil
                return e
            }
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
        while fs.has(destination) {
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

final class FakeAdmin: AdminActing, AdminRemoving, @unchecked Sendable {
    let fs: FakeFileSystem
    var performed: [(paths: [String], trashFolder: String)] = []
    var removed: [String] = []
    init(fs: FakeFileSystem) { self.fs = fs }

    func perform(_ items: [PlannedItem], trashFolder: String) -> [String: Result<String?, AdminError>] {
        performed.append((items.map(\.path), trashFolder))
        var results: [String: Result<String?, AdminError>] = [:]
        for item in items {
            let destination = trashFolder + "/" + Paths.lastComponent(item.path)
            do { try fs.move(item.path, to: destination); results[item.path] = .success(destination) }
            catch { results[item.path] = .failure(AdminError("\(error)")) }
        }
        return results
    }

    func removeForGood(_ paths: [String]) -> [String: Result<String?, AdminError>] {
        removed += paths
        var results: [String: Result<String?, AdminError>] = [:]
        for path in paths { fs.removeTree(path); results[path] = .success(nil) }
        return results
    }
}

final class FakeOpenFiles: OpenFileChecking, @unchecked Sendable {
    /// Open file path → process name.
    var open: [String: String] = [:]

    func openItems(under paths: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for path in paths {
            if let hit = open.first(where: { Paths.isWithin($0.key, path) }) { result[path] = hit.value }
        }
        return result
    }
}

final class FakeMounts: MountChecking, @unchecked Sendable {
    var mounted: Set<String>
    init(_ mounted: Set<String>) { self.mounted = mounted }
    func mountedVolumes() -> Set<String> { mounted }
}

final class MemoryPreferences: PreferenceStoring {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// A small machine: a startup disk (Data volume behind firmlinks) and a few external disks.
enum Fixture {
    static let home = "/Users/tester"
    static let data = "/System/Volumes/Data"
    static let uid: UInt32 = 501

    static let startup = Volume(name: "Macintosh HD", mountPoint: "/", scanRoot: data, kind: .startupData, fileSystemType: "apfs", isReadOnly: false)
    static let external = Volume(name: "Ext", mountPoint: "/Volumes/Ext", scanRoot: "/Volumes/Ext", kind: .external, fileSystemType: "apfs", isReadOnly: false)
    static let readOnly = Volume(name: "RO", mountPoint: "/Volumes/RO", scanRoot: "/Volumes/RO", kind: .external, fileSystemType: "apfs", isReadOnly: true)
    static let ntfs = Volume(name: "Win", mountPoint: "/Volumes/Win", scanRoot: "/Volumes/Win", kind: .external, fileSystemType: "ntfs", isReadOnly: false)
    static let timeMachine = Volume(name: "TM", mountPoint: "/Volumes/TM", scanRoot: "/Volumes/TM", kind: .timeMachine, fileSystemType: "apfs", isReadOnly: false)
    static let fat = Volume(name: "Stick", mountPoint: "/Volumes/Stick", scanRoot: "/Volumes/Stick", kind: .external, fileSystemType: "exfat", isReadOnly: false)
    static let volumes = [startup, external, readOnly, ntfs, timeMachine, fat]
    static let firmlinkMap = FirmlinkMap(linked: ["Users", "Applications", "Library", "private", "Volumes"])

    static func fileSystem() -> FakeFileSystem {
        let fs = FakeFileSystem()
        fs.addDir(data + home)
        fs.addDir(data + "/Applications")
        fs.addDir(data + "/Library")
        fs.addDir(data + "/private/var/db")
        fs.addDir("/System/Library")
        fs.addDir("/usr/bin")
        fs.addDir(data + "/Volumes")
        fs.firmlinks = ["/Users": data + "/Users", "/Applications": data + "/Applications", "/Library": data + "/Library",
                        "/private": data + "/private", "/Volumes": data + "/Volumes"]
        // The Data volume has its own real device, as on a real Mac (st_dev would be the same as /).
        fs.mount(data, device: 2)
        for (i, v) in volumes.dropFirst().enumerated() {
            fs.mount(data + v.mountPoint, device: UInt64(10 + i))
        }
        fs.addDir(home + "/.Trash")
        return fs
    }

    static func policy(_ fs: FakeFileSystem, allowlist: [String] = []) -> SafetyPolicy {
        SafetyPolicy(fileSystem: fs, home: home, volumes: volumes, allowlist: allowlist, selfBundlePath: "/Applications/Mac Clean.app")
    }

    static func trashFolder(_ mountPoint: String) -> String {
        TrashLocation.folder(forMountPoint: mountPoint, home: home, userID: uid)
    }

    /// Scans a volume of `fs` into a store, the way the app does.
    static func scan(_ fs: FakeFileSystem, volume: Volume, threads: Int = 3, isCancelled: @escaping @Sendable () -> Bool = { false })
        -> (NodeStore, ScanSummary) {
        let store = NodeStore(rootPath: volume.scanRoot, firmlinks: volume.kind == .startupData ? firmlinkMap : nil)
        var batches: [ScanBatch] = []
        let summary = Scanner(reader: fs, volume: volume, threads: threads).run(isCancelled: isCancelled) { batches.append($0) }
        for batch in batches { precondition(store.apply(batch), "batch out of order") }
        return (store, summary)
    }
}
