import UninstallCore
import Darwin
import Foundation

/// The real disk, read-only. Uses `lstat`, so symbolic links are described, never followed.
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
        return FileInfo(type: type, device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino,
                        linkCount: UInt64(st.st_nlink), allocatedSize: UInt64(st.st_blocks) * 512,
                        privateSize: type == .regular && st.st_nlink == 1 ? Self.privateSize(path) : nil,
                        modified: mtime, ownerID: st.st_uid)
    }

    public func contents(ofDirectory path: String) throws -> [String] {
        guard let dir = opendir(path) else { throw Self.error(errno, path) }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    public func readFile(_ path: String) throws -> Data {
        // O_NOFOLLOW: never read through a symbolic link.
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Self.error(errno, path) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
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
        default: .other(path, String(cString: strerror(code)))
        }
    }

    /// `ATTR_CMNEXT_PRIVATESIZE`: the bytes of an APFS file not shared with a clone. Nil if unsupported.
    static func privateSize(_ path: String) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // Layout: u_int32_t length, attribute_set_t returned, off_t private size.
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        let rc = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, options) }
        guard rc == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> UInt64? in
            let returned = raw.load(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let offset = 4 + MemoryLayout<attribute_set_t>.size
            return UInt64(raw.loadUnaligned(fromByteOffset: offset, as: Int64.self))
        }
    }
}
