import Darwin
import Foundation
import MacCleanCore

/// Lists folders with `getattrlistbulk`: one system call returns a batch of entries with every
/// attribute Mac Clean needs. Opens folders only (`O_DIRECTORY | O_NOFOLLOW`), never a file, so no
/// content is read and no iCloud download is triggered (see `Downloads.disableMaterialization`).
public struct BulkDirectoryReader: DirectoryReading {
    public init() {}

    static let common = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
    static let dir = attrgroup_t(ATTR_DIR_MOUNTSTATUS) | attrgroup_t(ATTR_DIR_ALLOCSIZE)
    static let file = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
    static let ext = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_REALDEVID) | attrgroup_t(ATTR_CMNEXT_CLONEID)
        | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)

    public func describe(_ path: String) throws -> DirectoryEntry {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_REALDEVID)
        var buffer = [UInt8](repeating: 0, count: 128)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        guard buffer.withUnsafeMutableBytes({ getattrlist(path, &list, $0.baseAddress, $0.count, options) }) == 0 else {
            throw RealFileSystem.error(errno, path)
        }
        return buffer.withUnsafeBytes { raw in
            var p = raw.baseAddress! + 4
            let returned = p.loadUnaligned(as: attribute_set_t.self)
            p += MemoryLayout<attribute_set_t>.size
            var type: UInt32 = 0
            var fileID: UInt64 = 0
            var realDevice: UInt64 = 0
            if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { type = p.loadUnaligned(as: UInt32.self); p += 4 }
            if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 { fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_REALDEVID) != 0 { realDevice = UInt64(p.loadUnaligned(as: UInt32.self)) }
            return DirectoryEntry(name: Paths.lastComponent(path), type: Self.fileType(type), realDevice: realDevice, fileID: fileID)
        }
    }

    public func entries(of path: String) throws -> [DirectoryEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RealFileSystem.error(errno, path) }
        defer { close(fd) }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = Self.common
        list.dirattr = Self.dir
        list.fileattr = Self.file
        list.forkattr = Self.ext
        let options = UInt64(FSOPT_ATTR_CMN_EXTENDED)
        let size = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        var result: [DirectoryEntry] = []
        while true {
            let count = getattrlistbulk(fd, &list, buffer, size, options)
            if count < 0 { throw RealFileSystem.error(errno, path) }
            if count == 0 { break }
            var p = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                if let entry = Self.parse(p) { result.append(entry) }
                p += length
            }
        }
        return result
    }

    static func fileType(_ vtype: UInt32) -> FileType {
        switch vtype {
        case UInt32(VDIR.rawValue): .directory
        case UInt32(VREG.rawValue): .regular
        case UInt32(VLNK.rawValue): .symlink
        default: .other
        }
    }

    /// Attributes come in a fixed order; only those in `returned` are present.
    static func parse(_ start: UnsafeRawPointer) -> DirectoryEntry? {
        var p = start + 4
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bit) != 0 }
        if has(returned.commonattr, ATTR_CMN_ERROR) {
            let error = p.loadUnaligned(as: UInt32.self)
            p += 4
            if error != 0 { return nil }
        }
        var e = DirectoryEntry(name: "", type: .other)
        if has(returned.commonattr, ATTR_CMN_NAME) {
            let ref = p.loadUnaligned(as: attrreference_t.self)
            // The length includes the terminating NUL.
            let bytes = UnsafeRawBufferPointer(start: p + Int(ref.attr_dataoffset), count: max(0, Int(ref.attr_length) - 1))
            e.name = String(decoding: bytes, as: UTF8.self)
            p += MemoryLayout<attrreference_t>.size
        }
        if has(returned.commonattr, ATTR_CMN_OBJTYPE) { e.type = fileType(p.loadUnaligned(as: UInt32.self)); p += 4 }
        if has(returned.commonattr, ATTR_CMN_CRTIME) { e.birth = Int64(p.loadUnaligned(as: timespec.self).tv_sec); p += MemoryLayout<timespec>.size }
        if has(returned.commonattr, ATTR_CMN_MODTIME) { e.modified = Int64(p.loadUnaligned(as: timespec.self).tv_sec); p += MemoryLayout<timespec>.size }
        if has(returned.commonattr, ATTR_CMN_FLAGS) {
            let flags = p.loadUnaligned(as: UInt32.self)
            e.isDataless = flags & UInt32(SF_DATALESS) != 0
            e.isCompressed = flags & UInt32(UF_COMPRESSED) != 0
            p += 4
        }
        if has(returned.commonattr, ATTR_CMN_FILEID) { e.fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
        if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) {
            e.isMountPoint = p.loadUnaligned(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
            p += 4
        }
        if has(returned.dirattr, ATTR_DIR_ALLOCSIZE) { e.allocatedSize = UInt64(max(0, p.loadUnaligned(as: Int64.self))); p += 8 }
        if has(returned.fileattr, ATTR_FILE_LINKCOUNT) { e.linkCount = p.loadUnaligned(as: UInt32.self); p += 4 }
        if has(returned.fileattr, ATTR_FILE_TOTALSIZE) { e.logicalSize = UInt64(max(0, p.loadUnaligned(as: Int64.self))); p += 8 }
        if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) { e.allocatedSize = UInt64(max(0, p.loadUnaligned(as: Int64.self))); p += 8 }
        if has(returned.forkattr, ATTR_CMNEXT_PRIVATESIZE) { e.privateSize = UInt64(max(0, p.loadUnaligned(as: Int64.self))); p += 8 }
        if has(returned.forkattr, ATTR_CMNEXT_REALDEVID) { e.realDevice = UInt64(p.loadUnaligned(as: UInt32.self)); p += 4 }
        if has(returned.forkattr, ATTR_CMNEXT_CLONEID) { e.cloneID = p.loadUnaligned(as: UInt64.self); p += 8 }
        if has(returned.forkattr, ATTR_CMNEXT_EXT_FLAGS) {
            let flags = p.loadUnaligned(as: UInt64.self)
            e.mayShareBlocks = flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
            e.isSparse = flags & UInt64(EF_IS_SPARSE) != 0
            e.isPurgeable = flags & UInt64(EF_IS_PURGEABLE) != 0
            p += 8
        }
        return e
    }
}

public enum Downloads {
    /// Reading attributes of a dataless (iCloud, File Provider) file must never download it. Applies
    /// to every thread of this process; call once at launch, before anything touches the disk.
    @discardableResult
    public static func disableMaterialization() -> Bool {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
    }
}
