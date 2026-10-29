import Darwin
import Foundation

/// The same scan with `fts` (one `lstat` per entry). Single thread.
struct FtsScanner {
    func scan(root: String) -> ScanTotals {
        var t = ScanTotals()
        var hardLinks = Set<UInt64>()
        let paths = [strdup(root), nil]
        defer { free(paths[0]) }
        guard let fts = paths.withUnsafeBufferPointer({ fts_open(UnsafeMutablePointer(mutating: $0.baseAddress!), FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) }) else {
            fatalError("fts_open failed")
        }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                if info == FTS_DNR { t.unreadableDirectories += 1 } else { t.entryErrors += 1 }
                continue
            }
            guard let st = entry.pointee.fts_statp?.pointee else { continue }
            if entry.pointee.fts_level == 1, info == FTS_D {
                let name = String(cString: entry.pointee.fts_path).split(separator: "/").last.map(String.init) ?? ""
                if systemFolderNames.contains(name) {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
            }
            if st.st_birthtimespec.tv_sec <= 0 { t.missingBirthTime += 1 }
            let allocated = UInt64(st.st_blocks) * 512
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                if entry.pointee.fts_level > 0 { t.directories += 1 } else { t.directories += 1 }
                t.directoryAllocated += allocated
            case S_IFREG:
                t.files += 1
                t.logical += UInt64(st.st_size)
                t.allocatedNaive += allocated
                if st.st_flags & UInt32(SF_DATALESS) != 0 { t.dataless += 1; t.datalessLogical += UInt64(st.st_size) }
                if st.st_flags & UInt32(UF_COMPRESSED) != 0 { t.compressed += 1 }
                if st.st_nlink > 1 && !hardLinks.insert(st.st_ino).inserted {
                    t.hardLinkExtras += 1
                    t.hardLinkExtraBytes += allocated
                } else {
                    t.allocated += allocated
                }
            case S_IFLNK:
                t.symlinks += 1
                t.allocatedNaive += allocated
                t.allocated += allocated
            default:
                t.others += 1
            }
        }
        // fts with FTS_XDEV still returns mount points (as directories) but does not descend.
        return t
    }
}

/// The same scan with `FileManager.enumerator` and URL resource values. Single thread. Hard links
/// cannot be told apart cheaply (no link count key), so `allocated` equals `allocatedNaive`.
struct FileManagerScanner {
    func scan(root: String) -> ScanTotals {
        var t = ScanTotals()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isVolumeKey,
                                      .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey,
                                      .creationDateKey, .contentModificationDateKey, .isPackageKey]
        let rootURL = URL(fileURLWithPath: root)
        var unreadable = 0
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in unreadable += 1; return true }) else {
            fatalError("no enumerator")
        }
        t.directories = 1
        var n = 0
        while true {
            let next: Bool = autoreleasepool {
                guard let url = enumerator.nextObject() as? URL else { return false }
                n += 1
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { t.entryErrors += 1; return true }
                if enumerator.level == 1, v.isDirectory == true, systemFolderNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    return true
                }
                if v.isVolume == true { t.otherVolumeMounts += 1; enumerator.skipDescendants(); return true }
                if v.creationDate == nil { t.missingBirthTime += 1 }
                if v.isSymbolicLink == true {
                    t.symlinks += 1
                } else if v.isDirectory == true {
                    t.directories += 1
                } else if v.isRegularFile == true {
                    t.files += 1
                    t.logical += UInt64(v.fileSize ?? 0)
                    let a = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                    t.allocatedNaive += a
                    t.allocated += a
                } else {
                    t.others += 1
                }
                return true
            }
            if !next { break }
        }
        t.unreadableDirectories = unreadable
        return t
    }
}
