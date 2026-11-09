import Foundation

public enum FileType: Sendable, Equatable {
    case regular, directory, symlink, other
}

/// One `lstat` result. Symbolic links are described, never followed.
public struct FileInfo: Sendable, Equatable {
    public var type: FileType
    public var device: UInt64
    public var inode: UInt64
    public var linkCount: UInt64
    /// Bytes actually allocated on disk for this entry alone (not its children).
    public var allocatedSize: UInt64
    /// For APFS clones: bytes not shared with any other file. `nil` when the volume can't say.
    public var privateSize: UInt64?
    public var modified: Date
    /// User ID of the owner. `nil` when unknown.
    public var ownerID: UInt32?

    public init(type: FileType, device: UInt64 = 1, inode: UInt64, linkCount: UInt64 = 1,
                allocatedSize: UInt64 = 0, privateSize: UInt64? = nil, modified: Date = .distantPast, ownerID: UInt32? = nil) {
        self.type = type
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.allocatedSize = allocatedSize
        self.privateSize = privateSize
        self.modified = modified
        self.ownerID = ownerID
    }
}

public enum FileSystemError: Error, Equatable {
    case notFound(String)
    /// Usually missing Full Disk Access, or a root-owned folder.
    case permissionDenied(String)
    case other(String, String)
}

/// Read-only view of a file system. Core never touches the disk except through this.
public protocol FileSystem: Sendable {
    func info(_ path: String) throws -> FileInfo
    /// Names in a directory (not paths), without `.` and `..`.
    func contents(ofDirectory path: String) throws -> [String]
    func readFile(_ path: String) throws -> Data
    /// The path with every symbolic link in it resolved (`realpath`). Used on parent folders only.
    func canonicalPath(_ path: String) throws -> String
}

public extension FileSystem {
    func exists(_ path: String) -> Bool { (try? info(path)) != nil }
    func isDirectory(_ path: String) -> Bool { (try? info(path))?.type == .directory }
}

/// Who can move an item: the user, or only an administrator.
public enum Ownership {
    /// An item owned by someone else (usually root, as for App Store apps) cannot be moved to the
    /// Trash without an administrator password, even inside a folder the user may write to:
    /// moving a folder needs write permission on the folder itself.
    public static func domain(of path: String, default domain: Domain, fileSystem: FileSystem, userID: UInt32?) -> Domain {
        guard domain == .user, let userID, let owner = (try? fileSystem.info(path))?.ownerID else { return domain }
        return owner == userID ? .user : .system
    }
}

public enum Paths {
    public static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
