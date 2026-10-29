import Foundation

/// What one scan of one volume found. Every method fills the same fields so they can be compared.
struct ScanTotals {
    var files = 0
    var directories = 0
    var symlinks = 0
    var others = 0
    /// Sum of logical sizes (what Finder calls "size").
    var logical: UInt64 = 0
    /// Sum of allocated sizes, every entry counted (hard links several times).
    var allocatedNaive: UInt64 = 0
    /// Allocated sizes with each hard-linked file counted once.
    var allocated: UInt64 = 0
    /// Of `allocated`: files that may share blocks with a clone.
    var clonedFiles = 0
    var clonedAllocated: UInt64 = 0
    /// Of the cloned files: bytes not shared with any other file (when the volume says).
    var clonedPrivate: UInt64 = 0
    var clonedPrivateKnown = 0
    /// Shared clone bytes counted once per clone id (an estimate of what clones really occupy).
    var clonedSharedOnce: UInt64 = 0
    var hardLinkExtras = 0
    var hardLinkExtraBytes: UInt64 = 0
    var dataless = 0
    var datalessLogical: UInt64 = 0
    var compressed = 0
    var sparse = 0
    var sparseLogical: UInt64 = 0
    var sparseAllocated: UInt64 = 0
    var purgeableFiles = 0
    var purgeableAllocated: UInt64 = 0
    var directoryAllocated: UInt64 = 0
    var unreadableDirectories = 0
    var otherVolumeMounts = 0
    /// Folders that are measured but kept apart (.Spotlight-V100, .fseventsd, ...).
    var systemFoldersAllocated: UInt64 = 0
    var missingBirthTime = 0
    var entryErrors = 0

    /// Bytes that would be freed if every file went: hard links once, clones by private size plus
    /// their shared part once per clone id.
    var estimatedOnDisk: UInt64 {
        allocated - clonedAllocated + clonedPrivate + clonedSharedOnce + directoryAllocated
    }

    mutating func merge(_ o: ScanTotals) {
        files += o.files; directories += o.directories; symlinks += o.symlinks; others += o.others
        logical += o.logical; allocatedNaive += o.allocatedNaive; allocated += o.allocated
        clonedFiles += o.clonedFiles; clonedAllocated += o.clonedAllocated; clonedPrivate += o.clonedPrivate
        clonedPrivateKnown += o.clonedPrivateKnown; clonedSharedOnce += o.clonedSharedOnce
        hardLinkExtras += o.hardLinkExtras; hardLinkExtraBytes += o.hardLinkExtraBytes
        dataless += o.dataless; datalessLogical += o.datalessLogical; compressed += o.compressed
        sparse += o.sparse; sparseLogical += o.sparseLogical; sparseAllocated += o.sparseAllocated
        purgeableFiles += o.purgeableFiles; purgeableAllocated += o.purgeableAllocated
        directoryAllocated += o.directoryAllocated; unreadableDirectories += o.unreadableDirectories
        otherVolumeMounts += o.otherVolumeMounts; systemFoldersAllocated += o.systemFoldersAllocated
        missingBirthTime += o.missingBirthTime; entryErrors += o.entryErrors
    }
}

/// Folders at a volume's root that hold system bookkeeping, not user data.
let systemFolderNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".Trashes",
                                      ".TemporaryItems", ".MobileBackups", ".PKInstallSandboxManager-SystemSoftware"]

/// Shared, locked bookkeeping for hard links and clones across scanning threads.
final class Dedup {
    private let lock = NSLock()
    private var hardLinks = Set<UInt64>()
    private var cloneShared: [UInt64: UInt64] = [:]

    /// True the first time a hard-linked file id is seen.
    func firstHardLink(_ id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return hardLinks.insert(id).inserted
    }

    /// Records the shared part of a clone; returns how much to add so each clone id counts its
    /// largest shared part once.
    func addShared(cloneID: UInt64, shared: UInt64) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let old = cloneShared[cloneID] ?? 0
        guard shared > old else { return 0 }
        cloneShared[cloneID] = shared
        return shared - old
    }

    var counts: (hardLinks: Int, cloneIDs: Int) {
        lock.lock(); defer { lock.unlock() }
        return (hardLinks.count, cloneShared.count)
    }
}

func formatBytes(_ b: UInt64) -> String {
    String(format: "%.2f GB", Double(b) / 1e9)
}

func maxRSS() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_maxrss)  // bytes on macOS
}

func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}
