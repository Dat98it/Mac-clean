import Foundation

/// One entry of a folder as the file system reports it, before Mac Clean decides anything.
public struct DirectoryEntry: Sendable, Equatable {
    public var name: String
    public var type: FileType
    /// The device of the volume that really holds the entry (`ATTR_CMNEXT_REALDEVID`). On the
    /// startup disk the system and Data volumes share `st_dev`; only this tells them apart.
    public var realDevice: UInt64
    public var fileID: UInt64
    public var linkCount: UInt32
    public var logicalSize: UInt64
    public var allocatedSize: UInt64
    /// Seconds since 1970, nil when not kept.
    public var birth: Int64?
    public var modified: Int64
    public var isMountPoint: Bool
    public var isDataless: Bool
    public var isCompressed: Bool
    public var mayShareBlocks: Bool
    public var isSparse: Bool
    public var isPurgeable: Bool
    /// Bytes of a clone not shared with any other file, when the volume says.
    public var privateSize: UInt64?
    public var cloneID: UInt64?

    public init(name: String, type: FileType, realDevice: UInt64 = 1, fileID: UInt64 = 0, linkCount: UInt32 = 1,
                logicalSize: UInt64 = 0, allocatedSize: UInt64 = 0, birth: Int64? = nil, modified: Int64 = 0,
                isMountPoint: Bool = false, isDataless: Bool = false, isCompressed: Bool = false, mayShareBlocks: Bool = false,
                isSparse: Bool = false, isPurgeable: Bool = false, privateSize: UInt64? = nil, cloneID: UInt64? = nil) {
        self.name = name
        self.type = type
        self.realDevice = realDevice
        self.fileID = fileID
        self.linkCount = linkCount
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.birth = birth
        self.modified = modified
        self.isMountPoint = isMountPoint
        self.isDataless = isDataless
        self.isCompressed = isCompressed
        self.mayShareBlocks = mayShareBlocks
        self.isSparse = isSparse
        self.isPurgeable = isPurgeable
        self.privateSize = privateSize
        self.cloneID = cloneID
    }
}

/// Lists folders, never following symbolic links, never opening files, never downloading
/// iCloud content. The real one uses `getattrlistbulk`.
public protocol DirectoryReading: Sendable {
    /// The entry for the folder itself (for its real device).
    func describe(_ path: String) throws -> DirectoryEntry
    func entries(of path: String) throws -> [DirectoryEntry]
}

/// What a scan saw beyond the tree itself: the numbers that explain the gap to `df`.
public struct ScanSummary: Sendable, Equatable {
    public var files = 0
    public var directories = 0
    public var symlinks = 0
    /// Sum of what nodes count (hard links once, clones at full size each).
    public var countedBytes: UInt64 = 0
    public var hardLinkExtras = 0
    public var hardLinkExtraBytes: UInt64 = 0
    /// Blocks shared between clones that were counted more than once (estimated by clone id).
    public var cloneSharedOvercount: UInt64 = 0
    public var datalessFiles = 0
    public var datalessLogicalBytes: UInt64 = 0
    public var purgeableBytes: UInt64 = 0
    /// .Spotlight-V100, .fseventsd, ... at the volume root: measured, not shown, never removable.
    public var systemFolderBytes: UInt64 = 0
    public var unreadableFolders: [String] = []
    public var unreadableCount = 0
    /// Folders left out because reading them needs Full Disk Access.
    public var needsFullDiskAccess: [String] = []
    public var skippedMounts = 0
    public var cancelled = false
    /// The volume disappeared (unplugged) during the scan.
    public var volumeGone = false
    public var duration: TimeInterval = 0

    public init() {}

    /// Best estimate of what the files take on disk.
    public var estimatedOnDisk: UInt64 { countedBytes - min(countedBytes, cloneSharedOvercount) }
}

public enum ScanRules {
    /// Folders macOS guards with its own permission prompts (TCC). Without Full Disk Access the
    /// scanner leaves them alone rather than bring up a dialog for each. Relative to the home folder.
    public static let privacyProtectedInHome = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                                                "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Messages",
                                                "Library/Safari", "Library/Calendars", "Library/Mobile Documents", "Library/CloudStorage",
                                                "Library/Cookies", "Library/HomeKit", "Library/Suggestions", "Library/Reminders",
                                                "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
                                                "Library/Application Support/com.apple.TCC", "Library/Application Support/Knowledge",
                                                "Library/Application Support/MobileSync", "Library/Metadata/CoreSpotlight",
                                                ".Trash"]

    /// Scan paths to leave out without Full Disk Access, for a volume scanned from `scanRoot`.
    public static func privacyExclusions(home: String, scanRoot: String, firmlinks: FirmlinkMap?) -> Set<String> {
        let base = firmlinks != nil ? scanRoot + home : home
        return Set(privacyProtectedInHome.map { base + "/" + $0 })
    }

    /// Bookkeeping folders at a volume's root. Measured apart; never shown as user data.
    public static let systemFolderNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".Trashes",
                                                       ".TemporaryItems", ".MobileBackups", ".PKInstallSandboxManager-SystemSoftware"]

    /// Folders shown as a single item (Finder's packages), by extension.
    public static let packageExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "kext", "photoslibrary",
                                                       "photolibrary", "aplibrary", "musiclibrary", "tvlibrary", "imovielibrary",
                                                       "fcpbundle", "logicx", "band", "xcarchive", "xcodeproj", "xcworkspace",
                                                       "playground", "pages", "numbers", "key", "rtfd", "sparsebundle",
                                                       "appex", "xpc", "qlgenerator", "mdimporter", "prefPane", "saver",
                                                       "dSYM", "lproj_bundle", "docset", "pkg", "mpkg", "wdgt", "scptd"]

    public static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && (packageExtensions.contains(ext) || packageExtensions.contains(ext.lowercased()))
    }

    static func clamp(_ seconds: Int64?) -> UInt32 {
        guard let s = seconds, s > 0 else { return 0 }
        return UInt32(min(s, Int64(UInt32.max)))
    }
}

/// Walks one volume and hands over its tree folder by folder. Several threads read folders at once;
/// batches go to `sink` one at a time, parents before children, with ids that follow each other.
/// Stays on the volume (real device), never follows links, never reads file contents.
public final class Scanner: @unchecked Sendable {
    public let reader: DirectoryReading
    public let volume: Volume
    public let threads: Int
    /// Folders (scan paths) not to open: without Full Disk Access, reading them would bring up a
    /// permission prompt for each. They are shown as unreadable instead.
    public let excluded: Set<String>

    public init(reader: DirectoryReading, volume: Volume, threads: Int = 8, excluded: Set<String> = []) {
        self.reader = reader
        self.volume = volume
        self.threads = max(1, threads)
        self.excluded = excluded
    }

    struct Work { var path: String; var node: NodeID; var depth: Int }

    /// Shared state of one run.
    final class Run: @unchecked Sendable {
        let lock = NSLock()
        let condition = NSCondition()
        var stack: [Work] = []
        var active = 0
        var nextID: NodeID = 1
        var summary = ScanSummary()
        var hardLinks = Set<UInt64>()
        var cloneShared: [UInt64: UInt64] = [:]
        var stop = false
    }

    /// Scans until done or `isCancelled` returns true. `sink` is called with the lock held: keep it short.
    public func run(isCancelled: @escaping @Sendable () -> Bool, sink: @escaping (ScanBatch) -> Void) -> ScanSummary {
        let started = Date()
        let run = Run()
        let rootDevice: UInt64
        do {
            rootDevice = try reader.describe(volume.scanRoot).realDevice
        } catch {
            var summary = ScanSummary()
            summary.volumeGone = (error as? FileSystemError).map { if case .volumeGone = $0 { return true } else { return false } } ?? false
            summary.unreadableFolders = [volume.scanRoot]
            summary.unreadableCount = 1
            summary.duration = Date().timeIntervalSince(started)
            return summary
        }
        run.stack = [Work(path: volume.scanRoot, node: 0, depth: 0)]
        run.summary.directories = 1

        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            while let work = pop(run, isCancelled: isCancelled) {
                let children = read(work, rootDevice: rootDevice, run: run, sink: sink)
                finish(run, adding: children)
            }
        }
        run.summary.cancelled = run.summary.cancelled || isCancelled()
        run.summary.duration = Date().timeIntervalSince(started)
        return run.summary
    }

    func pop(_ run: Run, isCancelled: () -> Bool) -> Work? {
        run.condition.lock(); defer { run.condition.unlock() }
        while true {
            if run.stop || isCancelled() {
                run.stop = true
                run.condition.broadcast()
                return nil
            }
            if !run.stack.isEmpty { break }
            if run.active == 0 { run.condition.broadcast(); return nil }
            run.condition.wait()
        }
        run.active += 1
        return run.stack.removeLast()
    }

    func finish(_ run: Run, adding work: [Work]) {
        run.condition.lock()
        if !run.stop { run.stack += work }
        run.active -= 1
        run.condition.broadcast()
        run.condition.unlock()
    }

    /// Reads one folder, decides what each entry counts for, and hands the batch over.
    func read(_ work: Work, rootDevice: UInt64, run: Run, sink: (ScanBatch) -> Void) -> [Work] {
        let entries: [DirectoryEntry]
        do {
            entries = try reader.entries(of: work.path)
        } catch {
            run.lock.lock()
            if case .volumeGone? = error as? FileSystemError {
                run.summary.volumeGone = true
                run.stop = true
            }
            run.summary.unreadableCount += 1
            if run.summary.unreadableFolders.count < 500 { run.summary.unreadableFolders.append(work.path) }
            sink(ScanBatch(parent: work.node, firstID: run.nextID, records: [], parentUnreadable: true))
            run.lock.unlock()
            return []
        }

        var records: [NodeRecord] = []
        var folders: [(index: Int, path: String)] = []
        var systemFolders: [String] = []
        records.reserveCapacity(entries.count)
        var local = ScanSummary()
        var hardLinked: [(index: Int, key: UInt64, bytes: UInt64)] = []
        var clones: [(id: UInt64, shared: UInt64)] = []

        for e in entries {
            // Never into another volume: a mount point, or anything on another device.
            if e.isMountPoint || e.realDevice != rootDevice {
                local.skippedMounts += 1
                continue
            }
            if work.depth == 0 && e.type == .directory && ScanRules.systemFolderNames.contains(e.name) {
                systemFolders.append(Paths.join(work.path, e.name))
                continue
            }
            var flags: NodeFlags = []
            var record = NodeRecord(name: e.name, kind: .other, allocated: e.allocatedSize, logical: e.logicalSize,
                                    birth: volume.hasBirthTime ? ScanRules.clamp(e.birth) : 0, modified: ScanRules.clamp(e.modified))
            switch e.type {
            case .directory:
                record.kind = .directory
                local.directories += 1
                if ScanRules.isPackage(e.name) { flags.insert(.package) }
                let path = Paths.join(work.path, e.name)
                if excluded.contains(path) {
                    flags.insert(.unreadable)
                    local.needsFullDiskAccess.append(path)
                } else {
                    folders.append((records.count, path))
                }
            case .regular:
                record.kind = .file
                local.files += 1
                if e.isDataless { flags.insert(.dataless); local.datalessFiles += 1; local.datalessLogicalBytes += e.logicalSize }
                if e.isCompressed { flags.insert(.compressed) }
                if e.isSparse { flags.insert(.sparse) }
                if e.isPurgeable { flags.insert(.purgeable); local.purgeableBytes += e.allocatedSize }
                if e.linkCount > 1 && volume.hasHardLinks {
                    hardLinked.append((records.count, e.fileID, e.allocatedSize))
                }
                if e.mayShareBlocks {
                    flags.insert(.clone)
                    if let priv = e.privateSize, let cid = e.cloneID {
                        clones.append((cid, e.allocatedSize - min(priv, e.allocatedSize)))
                    }
                }
            case .symlink:
                // Sized as the link itself, never followed.
                record.kind = .symlink
                local.symlinks += 1
            case .other:
                record.kind = .other
            }
            record.flags = flags
            records.append(record)
        }

        // System folders at the root: measured (sizes only), then left out of the tree.
        for path in systemFolders {
            local.systemFolderBytes += measure(path, rootDevice: rootDevice)
        }

        run.lock.lock()
        for h in hardLinked where !run.hardLinks.insert(h.key).inserted {
            records[h.index].allocated = 0
            records[h.index].flags.insert(.hardLinkExtra)
            local.hardLinkExtras += 1
            local.hardLinkExtraBytes += h.bytes
        }
        for c in clones {
            // Each clone's shared part was counted in full; keep only the largest per clone id.
            let previous = run.cloneShared[c.id]
            if let previous {
                local.cloneSharedOvercount += min(previous, c.shared)
                if c.shared > previous { run.cloneShared[c.id] = c.shared }
            } else {
                run.cloneShared[c.id] = c.shared
            }
        }
        local.countedBytes = records.reduce(0) { $0 + $1.allocated }
        let firstID = run.nextID
        run.nextID += NodeID(records.count)
        merge(local, into: &run.summary)
        sink(ScanBatch(parent: work.node, firstID: firstID, records: records))
        run.lock.unlock()

        return folders.map { Work(path: $0.path, node: firstID + NodeID($0.index), depth: work.depth + 1) }
    }

    /// Total allocated size below a folder, for the bookkeeping folders kept out of the tree.
    func measure(_ path: String, rootDevice: UInt64) -> UInt64 {
        var total: UInt64 = 0
        var stack = [path]
        while let folder = stack.popLast() {
            guard let entries = try? reader.entries(of: folder) else { continue }
            for e in entries where !e.isMountPoint && e.realDevice == rootDevice {
                total += e.allocatedSize
                if e.type == .directory { stack.append(Paths.join(folder, e.name)) }
            }
        }
        return total
    }

    func merge(_ o: ScanSummary, into s: inout ScanSummary) {
        s.files += o.files; s.directories += o.directories; s.symlinks += o.symlinks
        s.countedBytes += o.countedBytes; s.hardLinkExtras += o.hardLinkExtras; s.hardLinkExtraBytes += o.hardLinkExtraBytes
        s.cloneSharedOvercount += o.cloneSharedOvercount; s.datalessFiles += o.datalessFiles
        s.datalessLogicalBytes += o.datalessLogicalBytes; s.purgeableBytes += o.purgeableBytes
        s.systemFolderBytes += o.systemFolderBytes; s.skippedMounts += o.skippedMounts
        s.needsFullDiskAccess += o.needsFullDiskAccess
    }
}
