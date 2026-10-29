import Darwin
import Foundation

/// One mounted file system as `getfsstat` reports it, and how Mac Clean would treat it.
struct MountedVolume {
    var mountPoint: String
    var device: String
    var type: String
    var flags: UInt32
    var blockSize: UInt64
    var totalBytes: UInt64
    var freeBytes: UInt64
    var availableBytes: UInt64

    /// Space used by this volume alone (`ATTR_VOL_SPACEUSED`, what `df` shows on APFS). statfs on
    /// APFS reports the whole container, shared by every volume in it.
    var usedBytes: UInt64 { Self.spaceUsed(mountPoint) ?? (totalBytes - freeBytes) }

    static func spaceUsed(_ mountPoint: String) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 64)
        guard buffer.withUnsafeMutableBytes({ getattrlist(mountPoint, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) }) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> UInt64? in
            let returned = raw.load(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.volattr & attrgroup_t(ATTR_VOL_SPACEUSED) != 0 else { return nil }
            return UInt64(raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: Int64.self))
        }
    }
    var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }
    var isReadOnly: Bool { flags & UInt32(MNT_RDONLY) != 0 }
    var isBrowsable: Bool { flags & UInt32(MNT_DONTBROWSE) == 0 }
    var isRootFS: Bool { flags & UInt32(MNT_ROOTFS) != 0 }

    static let networkTypes: Set<String> = ["smbfs", "afpfs", "nfs", "webdav", "cifs", "ftp", "macfuse", "osxfuse", "fuse"]

    /// A Time Machine destination: the APFS "Backup" role cannot be read through statfs, so look
    /// for the folders Time Machine keeps at the root (reading their names only).
    var isTimeMachine: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: mountPoint + "/Backups.backupdb") || fm.fileExists(atPath: mountPoint + "/.timemachine")
    }

    var classification: String {
        if type == "devfs" || type == "autofs" { return "pseudo: skipped" }
        if !isLocal || Self.networkTypes.contains(type) { return "network: skipped" }
        if isTimeMachine { return "time machine: view only" }
        if mountPoint == "/" { return "startup system (sealed): total only" }
        if mountPoint == "/System/Volumes/Data" { return "startup data: scan" }
        if mountPoint.hasPrefix("/System/Volumes/") || !isBrowsable { return "system support: total only" }
        if type == "ntfs" || isReadOnly { return "read-only: view only" }
        return "external: scan, can trash"
    }

    static func all() -> [MountedVolume] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let got = getfsstat(buffer, Int32(Int(count) * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        return UnsafeBufferPointer(start: buffer, count: Int(max(0, min(got, count)))).map { s in
            var s = s
            func str<T>(_ t: inout T) -> String { withUnsafeBytes(of: &t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
            let bs = UInt64(s.f_bsize)
            return MountedVolume(mountPoint: str(&s.f_mntonname), device: str(&s.f_mntfromname), type: str(&s.f_fstypename),
                                 flags: s.f_flags, blockSize: bs, totalBytes: UInt64(s.f_blocks) * bs,
                                 freeBytes: UInt64(s.f_bfree) * bs, availableBytes: UInt64(s.f_bavail) * bs)
        }
    }
}
