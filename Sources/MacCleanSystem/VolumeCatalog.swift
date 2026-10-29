import Darwin
import Foundation
import MacCleanCore

/// Mounted file systems, read with `getfsstat(MNT_NOWAIT)`: cached figures, no I/O to the disks.
/// Network shares are never touched beyond that call.
public enum VolumeCatalog {
    public static func mounts() -> [MountRecord] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let got = getfsstat(buffer, Int32(Int(count) * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        return UnsafeBufferPointer(start: buffer, count: Int(max(0, min(got, count)))).map(record)
    }

    static func record(_ s: statfs) -> MountRecord {
        var s = s
        func text<T>(_ t: inout T) -> String { withUnsafeBytes(of: &t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
        let mountPoint = text(&s.f_mntonname)
        let type = text(&s.f_fstypename)
        let bs = UInt64(s.f_bsize)
        let local = s.f_flags & UInt32(MNT_LOCAL) != 0 && !VolumeCatalogRules.networkTypes.contains(type)
        // Only local disks are asked anything more.
        let used = local ? spaceUsed(mountPoint) : nil
        let tm = local && mountPoint.hasPrefix("/Volumes/")
            && (FileManager.default.fileExists(atPath: mountPoint + "/Backups.backupdb") || FileManager.default.fileExists(atPath: mountPoint + "/.timemachine"))
        return MountRecord(mountPoint: mountPoint, device: text(&s.f_mntfromname), fileSystemType: type, isLocal: local,
                           isReadOnly: s.f_flags & UInt32(MNT_RDONLY) != 0, isBrowsable: s.f_flags & UInt32(MNT_DONTBROWSE) == 0,
                           isRootFileSystem: s.f_flags & UInt32(MNT_ROOTFS) != 0,
                           usedBytes: used ?? (UInt64(s.f_blocks) - UInt64(s.f_bfree)) * bs, availableBytes: UInt64(s.f_bavail) * bs,
                           totalBytes: UInt64(s.f_blocks) * bs, filesInUse: UInt64(s.f_files) - UInt64(s.f_ffree),
                           hasTimeMachineMarkers: tm)
    }

    /// Space used by this volume alone (`ATTR_VOL_SPACEUSED`, as `df` shows on APFS). statfs on APFS
    /// reports the whole container.
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

    public static func firmlinks() -> FirmlinkMap {
        FirmlinkMap.parse((try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)) ?? "")
    }
}

/// Which disks are mounted right now.
public struct SystemMounts: MountChecking {
    public init() {}
    public func mountedVolumes() -> Set<String> {
        var result = Set(VolumeCatalog.mounts().map(\.mountPoint))
        // The startup disk is "/" in Mac Clean, scanned through /System/Volumes/Data.
        if result.contains(VolumeCatalogRules.startupDataMount) { result.insert("/") }
        return result
    }
}
