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
    public var size: UInt64
    /// Bytes actually allocated on disk for this entry alone (not its children).
    public var allocatedSize: UInt64
    public var modified: Date
    /// User ID of the owner. `nil` when unknown.
    public var ownerID: UInt32?

    public init(type: FileType, device: UInt64 = 1, inode: UInt64, linkCount: UInt64 = 1, size: UInt64 = 0,
                allocatedSize: UInt64 = 0, modified: Date = .distantPast, ownerID: UInt32? = nil) {
        self.type = type
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.size = size
        self.allocatedSize = allocatedSize
        self.modified = modified
        self.ownerID = ownerID
    }
}

public enum FileSystemError: Error, Equatable {
    case notFound(String)
    /// Usually missing Full Disk Access, or a folder protected by the system.
    case permissionDenied(String)
    /// The volume went away (unplugged) while it was being read.
    case volumeGone(String)
    case other(String, String)
}

/// Read-only view of a file system, one path at a time. Core never touches the disk except
/// through this and `DirectoryReading`.
public protocol FileSystem: Sendable {
    func info(_ path: String) throws -> FileInfo
    /// The path with every symbolic link in it resolved (`realpath`). Used on parent folders only.
    func canonicalPath(_ path: String) throws -> String
}

public extension FileSystem {
    func exists(_ path: String) -> Bool { (try? info(path)) != nil }
}

/// Who can move an item: the user, or only an administrator.
public enum Ownership: Sendable, Equatable {
    case user, administrator

    /// An item owned by someone else (usually root) cannot be moved to the Trash without an
    /// administrator password: moving a folder needs write permission on the folder itself.
    public static func of(_ path: String, fileSystem: FileSystem, userID: UInt32?) -> Ownership {
        guard let userID, let owner = (try? fileSystem.info(path))?.ownerID else { return .user }
        return owner == userID ? .user : .administrator
    }
}

public enum Paths {
    public static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    public static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// `path` is strictly below `folder`.
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        let base = folder == "/" ? "/" : folder + "/"
        return path.hasPrefix(base) && path.count > base.count
    }

    /// `path` is `folder` or below it.
    public static func isWithin(_ path: String, _ folder: String) -> Bool {
        path == folder || isInside(path, folder)
    }
}
