import Darwin
import Foundation

/// A prototype of the tree Mac Clean will keep: one array per field, indices instead of objects.
/// Parents always come before their children, so subtree sizes add up in one reverse pass.
final class SpikeNodeStore {
    var parent: [UInt32] = []
    var nameStart: [UInt32] = []
    var nameLength: [UInt16] = []
    var names: [UInt8] = []
    var allocated: [UInt64] = []
    var logical: [UInt64] = []
    var birth: [Int64] = []
    var modified: [Int64] = []
    var kind: [UInt8] = []
    var flags: [UInt8] = []
    var subtree: [UInt64] = []

    var count: Int { parent.count }

    func append(parent p: UInt32, name: UnsafeRawBufferPointer, allocated a: UInt64, logical l: UInt64,
                birth b: Int64, modified m: Int64, kind k: UInt8, flags f: UInt8) -> UInt32 {
        let index = UInt32(parent.count)
        parent.append(p)
        nameStart.append(UInt32(names.count))
        nameLength.append(UInt16(min(name.count, Int(UInt16.max))))
        names.append(contentsOf: name)
        allocated.append(a); logical.append(l); birth.append(b); modified.append(m)
        kind.append(k); flags.append(f); subtree.append(a)
        return index
    }

    func sumSubtrees() {
        guard count > 1 else { return }
        for i in stride(from: count - 1, to: 0, by: -1) {
            subtree[Int(parent[i])] += subtree[i]
        }
    }

    var bytesUsed: Int {
        parent.capacity * 4 + nameStart.capacity * 4 + nameLength.capacity * 2 + names.capacity
            + (allocated.capacity + logical.capacity + birth.capacity + modified.capacity + subtree.capacity) * 8
            + kind.capacity + flags.capacity
    }
}

/// Folders still to read, shared by the scanning threads. `pop` returns nil once the stack is
/// empty and no thread is still reading (so nothing more can be added).
final class WorkStack {
    struct Item { var path: String; var node: UInt32; var depth: Int }
    private var items: [Item]
    private var active = 0
    private let condition = NSCondition()

    init(_ root: Item) { items = [root] }

    func pop() -> Item? {
        condition.lock(); defer { condition.unlock() }
        while items.isEmpty {
            if active == 0 { condition.broadcast(); return nil }
            condition.wait()
        }
        active += 1
        return items.removeLast()
    }

    func finish(adding new: [Item]) {
        condition.lock()
        items += new
        active -= 1
        condition.broadcast()
        condition.unlock()
    }
}

/// Scans one volume with `getattrlistbulk`: one system call returns a batch of entries with
/// everything needed. Never follows symbolic links, never opens a file, never crosses into another volume.
struct BulkScanner {
    var threads: Int
    var store: SpikeNodeStore?
    var askPrivateSize = true

    static let common = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
        | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_CRTIME)
        | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
    static let dir = attrgroup_t(ATTR_DIR_MOUNTSTATUS) | attrgroup_t(ATTR_DIR_ALLOCSIZE)
    static let file = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
    static let ext = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)

    static let reportUnreadable = ProcessInfo.processInfo.environment["MACCLEAN_REPORT_UNREADABLE"] != nil

    struct Diagnostics {
        var privateSizeFromBulk = 0
        var privateSizeFromSingleCall = 0
        var cloneIDFromBulk = 0
        var extFlagsFromBulk = 0
        var birthFromBulk = 0
    }

    func scan(root: String) -> (ScanTotals, Diagnostics) {
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { fatalError("cannot read \(root)") }
        let device = Int32(rootStat.st_dev)
        var rootNode: UInt32 = 0
        if let store {
            rootNode = root.utf8CString.withUnsafeBytes { raw in
                store.append(parent: 0, name: UnsafeRawBufferPointer(rebasing: raw.dropLast()), allocated: 0, logical: 0,
                             birth: Int64(rootStat.st_birthtimespec.tv_sec), modified: Int64(rootStat.st_mtimespec.tv_sec),
                             kind: 1, flags: 0)
            }
        }
        let work = WorkStack(.init(path: root, node: rootNode, depth: 0))
        let dedup = Dedup()
        let storeLock = NSLock()
        let resultLock = NSLock()
        var totals = ScanTotals()
        var diagnostics = Diagnostics()
        totals.directories = 1

        DispatchQueue.concurrentPerform(iterations: max(1, threads)) { _ in
            var local = ScanTotals()
            var diag = Diagnostics()
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 8)
            defer { buffer.deallocate() }
            while let item = work.pop() {
                var subfolders: [WorkStack.Item] = []
                readFolder(item, device: device, buffer: buffer, dedup: dedup, storeLock: storeLock,
                           totals: &local, diag: &diag, subfolders: &subfolders)
                work.finish(adding: subfolders)
            }
            resultLock.lock()
            totals.merge(local)
            diagnostics.privateSizeFromBulk += diag.privateSizeFromBulk
            diagnostics.privateSizeFromSingleCall += diag.privateSizeFromSingleCall
            diagnostics.cloneIDFromBulk += diag.cloneIDFromBulk
            diagnostics.extFlagsFromBulk += diag.extFlagsFromBulk
            diagnostics.birthFromBulk += diag.birthFromBulk
            resultLock.unlock()
        }
        store?.sumSubtrees()
        return (totals, diagnostics)
    }

    /// One parsed entry from the bulk buffer, in the order the kernel packs attributes.
    struct Entry {
        var error: UInt32 = 0
        var name: UnsafeRawBufferPointer = UnsafeRawBufferPointer(start: nil, count: 0)
        var device: Int32 = 0
        var type: UInt32 = 0
        var birth: Int64? = nil
        var modified: Int64 = 0
        var flags: UInt32 = 0
        var fileID: UInt64 = 0
        var mountStatus: UInt32 = 0
        var dirAllocated: UInt64 = 0
        var linkCount: UInt32 = 1
        var totalSize: UInt64 = 0
        var allocated: UInt64 = 0
        var privateSize: UInt64? = nil
        var cloneID: UInt64? = nil
        var extFlags: UInt64? = nil
    }

    static func parse(_ start: UnsafeRawPointer) -> Entry {
        var e = Entry()
        var p = start + 4  // u_int32_t length
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p += MemoryLayout<attribute_set_t>.size
        func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bit) != 0 }
        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 { e.error = p.loadUnaligned(as: UInt32.self); p += 4 }
        if has(returned.commonattr, ATTR_CMN_NAME) {
            let ref = p.loadUnaligned(as: attrreference_t.self)
            // Length includes the terminating NUL.
            e.name = UnsafeRawBufferPointer(start: p + Int(ref.attr_dataoffset), count: max(0, Int(ref.attr_length) - 1))
            p += MemoryLayout<attrreference_t>.size
        }
        if has(returned.commonattr, ATTR_CMN_DEVID) { e.device = p.loadUnaligned(as: Int32.self); p += 4 }
        if has(returned.commonattr, ATTR_CMN_OBJTYPE) { e.type = p.loadUnaligned(as: UInt32.self); p += 4 }
        if has(returned.commonattr, ATTR_CMN_CRTIME) { e.birth = Int64(p.loadUnaligned(as: timespec.self).tv_sec); p += MemoryLayout<timespec>.size }
        if has(returned.commonattr, ATTR_CMN_MODTIME) { e.modified = Int64(p.loadUnaligned(as: timespec.self).tv_sec); p += MemoryLayout<timespec>.size }
        if has(returned.commonattr, ATTR_CMN_FLAGS) { e.flags = p.loadUnaligned(as: UInt32.self); p += 4 }
        if has(returned.commonattr, ATTR_CMN_FILEID) { e.fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
        if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) { e.mountStatus = p.loadUnaligned(as: UInt32.self); p += 4 }
        if has(returned.dirattr, ATTR_DIR_ALLOCSIZE) { e.dirAllocated = UInt64(max(0, p.loadUnaligned(as: Int64.self))); p += 8 }
        if has(returned.fileattr, ATTR_FILE_LINKCOUNT) { e.linkCount = p.loadUnaligned(as: UInt32.self); p += 4 }
        if has(returned.fileattr, ATTR_FILE_TOTALSIZE) { e.totalSize = UInt64(max(0, p.loadUnaligned(as: Int64.self))); p += 8 }
        if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) { e.allocated = UInt64(max(0, p.loadUnaligned(as: Int64.self))); p += 8 }
        if has(returned.forkattr, ATTR_CMNEXT_PRIVATESIZE) { e.privateSize = UInt64(max(0, p.loadUnaligned(as: Int64.self))); p += 8 }
        if has(returned.forkattr, ATTR_CMNEXT_CLONEID) { e.cloneID = p.loadUnaligned(as: UInt64.self); p += 8 }
        if has(returned.forkattr, ATTR_CMNEXT_EXT_FLAGS) { e.extFlags = p.loadUnaligned(as: UInt64.self); p += 8 }
        return e
    }

    func readFolder(_ item: WorkStack.Item, device: Int32, buffer: UnsafeMutableRawBufferPointer, dedup: Dedup,
                    storeLock: NSLock, totals t: inout ScanTotals, diag: inout Diagnostics, subfolders: inout [WorkStack.Item]) {
        let fd = open(item.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            t.unreadableDirectories += 1
            if Self.reportUnreadable { FileHandle.standardError.write(Data("unreadable \(String(cString: strerror(errno))): \(item.path)\n".utf8)) }
            return
        }
        defer { close(fd) }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = Self.common
        list.dirattr = Self.dir
        list.fileattr = Self.file
        list.forkattr = Self.ext
        let options = UInt64(FSOPT_NOFOLLOW) | UInt64(FSOPT_ATTR_CMN_EXTENDED)

        // Entries of this folder, stored together under one lock.
        struct Pending { var entry: Entry; var nameBytes: [UInt8]; var kind: UInt8; var flags: UInt8; var isFolder: Bool }
        var pending: [Pending] = []
        let isRoot = item.depth == 0

        while true {
            let count = getattrlistbulk(fd, &list, buffer.baseAddress!, buffer.count, options)
            if count < 0 {
                t.unreadableDirectories += 1
                if Self.reportUnreadable { FileHandle.standardError.write(Data("unreadable (bulk) \(String(cString: strerror(errno))): \(item.path)\n".utf8)) }
                break
            }
            if count == 0 { break }
            var p = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<count {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                defer { p += length }
                let e = Self.parse(p)
                if e.error != 0 { t.entryErrors += 1; continue }
                let name = String(decoding: e.name, as: UTF8.self)
                if isRoot && e.type == UInt32(VDIR.rawValue) && systemFolderNames.contains(name) {
                    // Measured separately and kept out of the main totals.
                    let sub = BulkScanner(threads: 1, store: nil, askPrivateSize: false).scan(root: Self.join(item.path, name)).0
                    t.systemFoldersAllocated += sub.allocated + sub.directoryAllocated
                    continue
                }
                var kind: UInt8 = 0
                var nodeFlags: UInt8 = 0
                var isFolder = false
                if e.birth != nil { diag.birthFromBulk += 1 } else { t.missingBirthTime += 1 }
                if e.extFlags != nil { diag.extFlagsFromBulk += 1 }
                switch e.type {
                case UInt32(VDIR.rawValue):
                    if e.device != device || e.mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 {
                        t.otherVolumeMounts += 1
                        continue
                    }
                    t.directories += 1
                    t.directoryAllocated += e.dirAllocated
                    kind = 1
                    isFolder = true
                case UInt32(VREG.rawValue):
                    t.files += 1
                    t.logical += e.totalSize
                    t.allocatedNaive += e.allocated
                    kind = 2
                    if e.flags & UInt32(SF_DATALESS) != 0 { t.dataless += 1; t.datalessLogical += e.totalSize; nodeFlags |= 1 }
                    if e.flags & UInt32(UF_COMPRESSED) != 0 { t.compressed += 1; nodeFlags |= 2 }
                    let ext = e.extFlags ?? 0
                    if ext & UInt64(EF_IS_SPARSE) != 0 { t.sparse += 1; t.sparseLogical += e.totalSize; t.sparseAllocated += e.allocated }
                    if ext & UInt64(EF_IS_PURGEABLE) != 0 { t.purgeableFiles += 1; t.purgeableAllocated += e.allocated }
                    if e.linkCount > 1 && !dedup.firstHardLink(e.fileID) {
                        t.hardLinkExtras += 1
                        t.hardLinkExtraBytes += e.allocated
                        nodeFlags |= 4
                        break
                    }
                    t.allocated += e.allocated
                    if ext & UInt64(EF_MAY_SHARE_BLOCKS) != 0 {
                        t.clonedFiles += 1
                        t.clonedAllocated += e.allocated
                        nodeFlags |= 8
                        var privateSize = e.privateSize
                        if privateSize != nil { diag.privateSizeFromBulk += 1 }
                        if privateSize == nil && askPrivateSize {
                            privateSize = Self.privateSize(dirfd: fd, name: name)
                            if privateSize != nil { diag.privateSizeFromSingleCall += 1 }
                        }
                        if e.cloneID != nil { diag.cloneIDFromBulk += 1 }
                        if let ps = privateSize {
                            let priv = min(ps, e.allocated)
                            t.clonedPrivate += priv
                            t.clonedPrivateKnown += 1
                            if let cid = e.cloneID {
                                t.clonedSharedOnce += dedup.addShared(cloneID: cid, shared: e.allocated - priv)
                            } else {
                                t.clonedSharedOnce += e.allocated - priv
                            }
                        } else {
                            t.clonedPrivate += e.allocated
                        }
                    }
                case UInt32(VLNK.rawValue):
                    t.symlinks += 1
                    t.allocatedNaive += e.allocated
                    t.allocated += e.allocated
                    kind = 3
                default:
                    t.others += 1
                    kind = 4
                }
                if store != nil {
                    pending.append(Pending(entry: e, nameBytes: Array(e.name), kind: kind, flags: nodeFlags, isFolder: isFolder))
                } else if isFolder {
                    subfolders.append(.init(path: Self.join(item.path, name), node: 0, depth: item.depth + 1))
                }
            }
        }
        guard let store, !pending.isEmpty else { return }
        storeLock.lock()
        var indices: [UInt32] = []
        indices.reserveCapacity(pending.count)
        for entry in pending {
            let index = entry.nameBytes.withUnsafeBytes { raw in
                store.append(parent: item.node, name: raw, allocated: entry.kind == 1 ? entry.entry.dirAllocated : entry.entry.allocated,
                             logical: entry.entry.totalSize, birth: entry.entry.birth ?? 0, modified: entry.entry.modified,
                             kind: entry.kind, flags: entry.flags)
            }
            indices.append(index)
        }
        storeLock.unlock()
        for (entry, index) in zip(pending, indices) where entry.isFolder {
            subfolders.append(.init(path: Self.join(item.path, String(decoding: entry.nameBytes, as: UTF8.self)), node: index, depth: item.depth + 1))
        }
    }

    static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    /// `ATTR_CMNEXT_PRIVATESIZE` for one file, relative to its folder. Never follows a link.
    static func privateSize(dirfd: Int32, name: String) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        let rc = buffer.withUnsafeMutableBytes { getattrlistat(dirfd, name, &list, $0.baseAddress, $0.count, UInt(options)) }
        guard rc == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> UInt64? in
            let returned = raw.load(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return UInt64(raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: Int64.self))
        }
    }
}
