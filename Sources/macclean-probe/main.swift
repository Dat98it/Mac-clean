import Darwin
import Foundation
import MacCleanCore
import MacCleanSystem

// Never download iCloud or File Provider content: reading attributes of a dataless file must not
// materialize it. Set before anything touches the disk; applies to every thread of this process.
let iopolicyResult = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

let usage = """
macclean-probe: read-only diagnosis. Nothing here writes, moves or deletes.
  volumes                                   mounted volumes and how Mac Clean would treat them
  bench bulk|fts|fm <root> [--threads N] [--store] [--no-private]
                                            scan one volume, print totals, time and memory
  dataless <dir>                            count dataless (not downloaded) files and confirm they stay so
  scan <mount point> [--no-fda]             the app's own scan (Core + getattrlistbulk + NodeStore): time,
                                            memory, gap to df, search and sort timings
"""

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func printTotals(_ t: ScanTotals) {
    let rows: [(String, String)] = [
        ("files", "\(t.files)"), ("directories", "\(t.directories)"), ("symlinks", "\(t.symlinks)"), ("others", "\(t.others)"),
        ("logical", formatBytes(t.logical)), ("allocated naive", formatBytes(t.allocatedNaive)),
        ("allocated (hard links once)", formatBytes(t.allocated)),
        ("hard link extras", "\(t.hardLinkExtras) / \(formatBytes(t.hardLinkExtraBytes))"),
        ("cloned files", "\(t.clonedFiles) / alloc \(formatBytes(t.clonedAllocated)) / private \(formatBytes(t.clonedPrivate)) (known \(t.clonedPrivateKnown)) / shared once \(formatBytes(t.clonedSharedOnce))"),
        ("directory allocated", formatBytes(t.directoryAllocated)),
        ("estimated on disk", formatBytes(t.estimatedOnDisk)),
        ("dataless", "\(t.dataless) / logical \(formatBytes(t.datalessLogical))"),
        ("compressed", "\(t.compressed)"),
        ("sparse", "\(t.sparse) / logical \(formatBytes(t.sparseLogical)) / alloc \(formatBytes(t.sparseAllocated))"),
        ("purgeable files", "\(t.purgeableFiles) / \(formatBytes(t.purgeableAllocated))"),
        ("system folders (kept apart)", formatBytes(t.systemFoldersAllocated)),
        ("unreadable directories", "\(t.unreadableDirectories)"), ("other volume mounts", "\(t.otherVolumeMounts)"),
        ("missing birth time", "\(t.missingBirthTime)"), ("entry errors", "\(t.entryErrors)"),
    ]
    for (k, v) in rows { print(k.padding(toLength: 30, withPad: " ", startingAt: 0) + v) }
}

switch args.first {
case "volumes":
    print("iopolicy materialize-off: \(iopolicyResult == 0 ? "ok" : "FAILED")")
    for v in MountedVolume.all() where v.classification != "network: skipped" {
        print([v.mountPoint, v.device, v.type, "used \(formatBytes(v.usedBytes))", "free \(formatBytes(v.availableBytes))",
               v.isReadOnly ? "ro" : "rw", v.isLocal ? "local" : "remote", v.classification].joined(separator: " | "))
    }

case "bench":
    guard args.count >= 3 else { print(usage); exit(2) }
    let method = args[1], root = args[2]
    let threads = Int(option("--threads") ?? "1") ?? 1
    let start = Date()
    var totals = ScanTotals()
    var storeInfo = ""
    switch method {
    case "bulk":
        let store = args.contains("--store") ? SpikeNodeStore() : nil
        let (t, d) = BulkScanner(threads: threads, store: store, askPrivateSize: !args.contains("--no-private")).scan(root: root)
        totals = t
        print("bulk diagnostics: privateSize from bulk \(d.privateSizeFromBulk), from single call \(d.privateSizeFromSingleCall), cloneID from bulk \(d.cloneIDFromBulk), ext flags from bulk \(d.extFlagsFromBulk), birth from bulk \(d.birthFromBulk)")
        if let store { storeInfo = "store: \(store.count) nodes, \(store.bytesUsed / 1_000_000) MB arrays, root subtree \(formatBytes(store.subtree[0]))" }
    case "fts": totals = FtsScanner().scan(root: root)
    case "fm": totals = FileManagerScanner().scan(root: root)
    default: print(usage); exit(2)
    }
    let elapsed = Date().timeIntervalSince(start)
    print("method \(method) threads \(threads) root \(root)")
    print(String(format: "time %.1f s, %.0f entries/s, max RSS %d MB, footprint %d MB", elapsed,
                 Double(totals.files + totals.directories + totals.symlinks + totals.others) / elapsed,
                 maxRSS() / 1_000_000, physFootprint() / 1_000_000))
    if !storeInfo.isEmpty { print(storeInfo) }
    printTotals(totals)

case "dataless":
    guard args.count >= 2 else { print(usage); exit(2) }
    let first = BulkScanner(threads: 4, store: nil, askPrivateSize: false).scan(root: args[1]).0
    let second = BulkScanner(threads: 4, store: nil, askPrivateSize: false).scan(root: args[1]).0
    print("iopolicy materialize-off: \(iopolicyResult == 0 ? "ok" : "FAILED")")
    print("dataless before \(first.dataless) (\(formatBytes(first.datalessLogical)) logical), after \(second.dataless); files \(first.files); allocated \(formatBytes(first.allocated))")

case "scan":
    guard args.count >= 2 else { print(usage); exit(2) }
    let env = MacCleanEnvironment.live(selfBundlePath: nil)
    guard let volume = env.volumes().first(where: { $0.mountPoint == args[1] }) else {
        print("no such volume; volumes: \(env.volumes().map(\.mountPoint))"); exit(2)
    }
    let firmlinks = env.firmlinks(for: volume)
    let excluded = args.contains("--no-fda") ? ScanRules.privacyExclusions(home: env.home, scanRoot: volume.scanRoot, firmlinks: firmlinks) : []
    let store = MacCleanCore.NodeStore(rootPath: volume.scanRoot, firmlinks: firmlinks, expectedCount: Int(min(volume.filesInUse, 4_000_000)))
    let queue = DispatchQueue(label: "apply")
    let started = Date()
    let summary = MacCleanCore.Scanner(reader: env.reader, volume: volume, threads: 8, excluded: Set(excluded)).run(isCancelled: { false }) { batch in
        queue.async { precondition(store.apply(batch)) }
    }
    queue.sync {}
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "%@ (%@): %d nodes in %.1f s, max RSS %d MB, footprint %d MB, store arrays %d MB", volume.name, volume.scanRoot,
                 store.count, elapsed, maxRSS() / 1_000_000, physFootprint() / 1_000_000, store.memoryBytes / 1_000_000))
    let used = volume.usedBytes
    let found = summary.estimatedOnDisk + summary.systemFolderBytes
    print("df used \(formatBytes(used)); tree \(formatBytes(store.size(0))); estimated on disk \(formatBytes(summary.estimatedOnDisk)); bookkeeping \(formatBytes(summary.systemFolderBytes))")
    print(String(format: "gap to df: %@ (%.2f%%)", formatBytes(UInt64(max(0, Int64(used) - Int64(found)))), (Double(used) - Double(found)) / Double(used) * 100))
    print("hard link extras \(summary.hardLinkExtras), clone overcount \(formatBytes(summary.cloneSharedOvercount)), dataless \(summary.datalessFiles), unreadable \(summary.unreadableCount), left out for FDA \(summary.needsFullDiskAccess.count), mounts skipped \(summary.skippedMounts)")
    for part in volume.otherParts { print("  other part: \(part.name) \(formatBytes(part.bytes))") }
    var t = Date()
    let top = Browse.children(of: 0, in: store, order: .default, filter: BrowseFilter())
    print(String(format: "sort root children by size: %.3f s; largest: %@", Date().timeIntervalSince(t), top.prefix(5).map { store.name($0) + " " + formatBytes(store.size($0)) }.joined(separator: ", ")))
    t = Date()
    let byName = Browse.children(of: 0, in: store, order: SortOrder(column: .name, ascending: true), filter: BrowseFilter())
    print(String(format: "sort root children by name: %.3f s (%d)", Date().timeIntervalSince(t), byName.count))
    t = Date()
    let hits = Browse.matches(in: store, filter: BrowseFilter(name: "cache"), order: .default, now: Date())
    print(String(format: "name filter 'cache' over %d nodes: %.2f s, %d shown (truncated %@)", store.count, Date().timeIntervalSince(t), hits.ids.count, hits.truncated ? "yes" : "no"))
    t = Date()
    let old = Browse.matches(in: store, filter: BrowseFilter(minimumSize: 100_000_000, minimumAgeDays: 365), order: .default, now: Date())
    print(String(format: "age filter (>1 year, >=100 MB): %.2f s, %d", Date().timeIntervalSince(t), old.ids.count))
    if volume.kind == .startupData {
        t = Date()
        let suggestions = SuggestionFinder.find(in: store, home: env.home, now: Date())
        print(String(format: "suggestions: %.2f s", Date().timeIntervalSince(t)))
        for s in suggestions { print("  \(s.title): \(s.items.count) items, \(formatBytes(s.totalBytes)), selected \(s.items.filter(\.isSelected).count)") }
    }
    print(String(format: "final max RSS %d MB", maxRSS() / 1_000_000))

default:
    print(usage)
}
