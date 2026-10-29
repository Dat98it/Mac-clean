import Darwin
import Foundation
import MacCleanCore

/// The real disk, read-only, one path at a time. Uses `lstat`, so symbolic links are described,
/// never followed. Adapted from App Clean's RealFileSystem.
public struct RealFileSystem: FileSystem {
    public init() {}

    public func info(_ path: String) throws -> FileInfo {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw Self.error(errno, path) }
        let type: FileType
        switch st.st_mode & S_IFMT {
        case S_IFREG: type = .regular
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symlink
        default: type = .other
        }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return FileInfo(type: type, device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino, linkCount: UInt64(st.st_nlink),
                        size: UInt64(max(0, st.st_size)), allocatedSize: UInt64(st.st_blocks) * 512, modified: mtime, ownerID: st.st_uid)
    }

    public func canonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw Self.error(errno, path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func error(_ code: Int32, _ path: String) -> FileSystemError {
        switch code {
        case ENOENT, ENOTDIR: .notFound(path)
        case EACCES, EPERM: .permissionDenied(path)
        // An unplugged disk: the device is gone or no longer answers.
        case ENXIO, ENODEV, EIO: .volumeGone(path)
        default: .other(path, String(cString: strerror(code)))
        }
    }
}
