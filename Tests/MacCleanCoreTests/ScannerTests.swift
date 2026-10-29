import Foundation
import Testing
@testable import MacCleanCore

@Suite struct ScannerTests {
    let home = Fixture.home
    let data = Fixture.data

    @Test func buildsTheTreeWithFolderTotals() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/Downloads/a.dmg", size: 1000)
        fs.addFile(data + home + "/Downloads/sub/b.zip", size: 300)
        let (store, summary) = Fixture.scan(fs, volume: Fixture.startup)
        let downloads = store.find(home + "/Downloads")!
        #expect(store.size(downloads) == 1300)
        #expect(store.size(0) == summary.countedBytes)
        #expect(store.path(store.find(home + "/Downloads/sub/b.zip")!) == home + "/Downloads/sub/b.zip")
        #expect(store.scanPath(downloads) == data + home + "/Downloads")
        #expect(summary.files == 2)
        #expect(!summary.cancelled && !summary.volumeGone)
    }

    @Test func neverCrossesIntoAnotherVolume() {
        let fs = Fixture.fileSystem()
        fs.addFile("/Volumes/Ext/huge.bin", size: 9_000_000)
        fs.addFile(data + home + "/a", size: 10)
        let (store, summary) = Fixture.scan(fs, volume: Fixture.startup)
        #expect(store.find("/Volumes/Ext/huge.bin") == nil)
        #expect(store.find("/Volumes/Ext") == nil)
        #expect(store.size(0) == 10)
        #expect(summary.skippedMounts == Fixture.volumes.count - 1)
    }

    /// The startup disk's system and Data volumes share st_dev; only the real device separates
    /// them. An entry on another real device that is not flagged as a mount point is still skipped.
    @Test func realDeviceDecidesEvenWithoutMountFlag() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/a", size: 10)
        fs.addDir(data + "/firmlinked")
        fs.devices[data + "/firmlinked"] = 99
        fs.mount(data + "/firmlinked", device: 99)
        fs.addFile(data + "/firmlinked/system-file", size: 5000)
        fs.devices[data + "/firmlinked"] = nil  // no longer reported as a mount point
        let (store, _) = Fixture.scan(fs, volume: Fixture.startup)
        #expect(store.find(data + "/firmlinked") == nil)
        #expect(store.size(0) == 10)
    }

    /// A mount point on the same device (a bind or trigger mount) is still another file system.
    @Test func mountPointFlagAloneStopsTheScan() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + "/mnt/inside", size: 70)
        fs.devices[data + "/mnt"] = 2
        let (store, _) = Fixture.scan(fs, volume: Fixture.startup)
        #expect(store.find(data + "/mnt") == nil)
        #expect(store.size(0) == 0)
    }

    @Test func hardLinksCountOnce() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/a/one", size: 500, inode: 7, linkCount: 2)
        fs.addFile(data + home + "/b/two", size: 500, inode: 7, linkCount: 2)
        let (store, summary) = Fixture.scan(fs, volume: Fixture.startup)
        #expect(store.size(0) == 500)
        #expect(summary.hardLinkExtras == 1)
        let flagged = [home + "/a/one", home + "/b/two"].compactMap { store.find($0) }.filter { store.flags($0).contains(.hardLinkExtra) }
        #expect(flagged.count == 1)
    }

    @Test func fatVolumesHaveNoHardLinksOrBirthTimes() {
        let fs = Fixture.fileSystem()
        fs.addFile("/Volumes/Stick/a", size: 500, birth: 5000, inode: 7, linkCount: 2)
        fs.addFile("/Volumes/Stick/b", size: 500, inode: 7, linkCount: 2)
        let (store, _) = Fixture.scan(fs, volume: Fixture.fat)
        #expect(store.size(0) == 1000)
        #expect(store.birthDate(store.find("/Volumes/Stick/a")!) == nil)
    }

    @Test func clonesSharedPartIsCountedOnceInTheEstimate() {
        let fs = Fixture.fileSystem()
        // Two clones of a 1000-byte file, each with 100 bytes of its own.
        fs.addFile(data + home + "/c1", size: 1000, clone: (100, 42))
        fs.addFile(data + home + "/c2", size: 1000, clone: (100, 42))
        let (store, summary) = Fixture.scan(fs, volume: Fixture.startup)
        #expect(store.size(0) == 2000)
        #expect(summary.cloneSharedOvercount == 900)
        #expect(summary.estimatedOnDisk == 1100)
        #expect(store.flags(store.find(home + "/c1")!).contains(.clone))
    }

    @Test func symbolicLinksAreNotFollowed() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/Big/movie", size: 5000)
        fs.addSymlink(data + home + "/Shortcut", to: home + "/Big")
        let (store, _) = Fixture.scan(fs, volume: Fixture.startup)
        let link = store.find(home + "/Shortcut")!
        #expect(store.kind(link) == .symlink)
        #expect(store.children(link).isEmpty)
        #expect(store.size(0) == 5000)
    }

    @Test func bookkeepingFoldersAreMeasuredApart() {
        let fs = Fixture.fileSystem()
        fs.addFile("/Volumes/Ext/.Spotlight-V100/index", size: 700)
        fs.addFile("/Volumes/Ext/.fseventsd/0001", size: 50)
        fs.addFile("/Volumes/Ext/photo.jpg", size: 100)
        let (store, summary) = Fixture.scan(fs, volume: Fixture.external)
        #expect(store.find("/Volumes/Ext/.Spotlight-V100") == nil)
        #expect(summary.systemFolderBytes == 750)
        #expect(store.size(0) == 100)
    }

    @Test func unreadableFoldersAreFlaggedAndListed() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + "/private/var/db/secret/x", size: 10)
        fs.denied.insert(data + "/private/var/db/secret")
        let (store, summary) = Fixture.scan(fs, volume: Fixture.startup)
        #expect(summary.unreadableFolders == [data + "/private/var/db/secret"])
        #expect(store.flags(store.find("/private/var/db/secret")!).contains(.unreadable))
    }

    @Test func privacyProtectedFoldersAreLeftAloneWithoutFullDiskAccess() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/Documents/secret.pages", size: 500)
        fs.addFile(data + home + "/Projects/a", size: 10)
        var opened: [String] = []
        fs.onList = { opened.append($0) }
        let excluded = ScanRules.privacyExclusions(home: home, scanRoot: data, firmlinks: Fixture.firmlinkMap)
        let store = NodeStore(rootPath: data, firmlinks: Fixture.firmlinkMap)
        var batches: [ScanBatch] = []
        let summary = Scanner(reader: fs, volume: Fixture.startup, threads: 1, excluded: excluded).run(isCancelled: { false }) { batches.append($0) }
        for b in batches { store.apply(b) }
        #expect(!opened.contains(data + home + "/Documents"))
        #expect(summary.needsFullDiskAccess.sorted() == [data + home + "/.Trash", data + home + "/Documents"])
        let documents = store.find(home + "/Documents")!
        #expect(store.flags(documents).contains(.unreadable))
        #expect(store.size(0) == 10)
    }

    @Test func removingANodeTakesItsSizeOffItsAncestors() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/A/x/big", size: 1000)
        fs.addFile(data + home + "/A/y", size: 5)
        let (store, _) = Fixture.scan(fs, volume: Fixture.startup)
        let x = store.find(home + "/A/x")!
        let big = store.find(home + "/A/x/big")!
        #expect(store.remove(x))
        #expect(store.size(store.find(home + "/A")!) == 5)
        #expect(store.size(0) == 5)
        #expect(store.find(home + "/A/x") == nil)
        #expect(!store.isInTree(big))
        #expect(!store.remove(x))
        #expect(Browse.matches(in: store, filter: BrowseFilter(name: "big"), order: .default, now: Date()).ids.isEmpty)
    }

    @Test func packagesAreFlagged() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + "/Applications/Tool.app/Contents/MacOS/Tool", size: 10)
        let (store, _) = Fixture.scan(fs, volume: Fixture.startup)
        let app = store.find("/Applications/Tool.app")!
        #expect(store.flags(app).contains(.package))
        #expect(!store.isExpandable(app))
        #expect(store.isExpandable(app, intoPackages: true))
        #expect(store.size(app) == 10)
    }

    @Test func datalessFilesAreFlaggedAndTakeNoSpace() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/Library/Mobile Documents/doc.pages", size: 9000, dataless: true)
        let (store, summary) = Fixture.scan(fs, volume: Fixture.startup)
        let node = store.find(home + "/Library/Mobile Documents/doc.pages")!
        #expect(store.flags(node).contains(.dataless))
        #expect(store.size(node) == 0)
        #expect(summary.datalessFiles == 1)
    }

    @Test func cancelStopsTheScan() {
        let fs = Fixture.fileSystem()
        for i in 0..<50 { fs.addFile(data + home + "/d\(i)/f", size: 1) }
        let flag = Flag()
        fs.onList = { path in if path.hasSuffix("/d3") { flag.set() } }
        let (store, summary) = Fixture.scan(fs, volume: Fixture.startup, threads: 1, isCancelled: { flag.value })
        #expect(summary.cancelled)
        #expect(store.count < 100)
    }

    @Test func unpluggedVolumeEndsTheScanWithAClearState() {
        let fs = Fixture.fileSystem()
        for i in 0..<20 { fs.addFile("/Volumes/Ext/d\(i)/f", size: 1) }
        fs.onList = { path in if path.hasSuffix("/d5") { fs.gone.insert("/Volumes/Ext") } }
        let (_, summary) = Fixture.scan(fs, volume: Fixture.external, threads: 1)
        #expect(summary.volumeGone)
    }

    @Test func missingRootReportsVolumeGone() {
        let fs = Fixture.fileSystem()
        fs.gone.insert("/Volumes/Ext")
        let (store, summary) = Fixture.scan(fs, volume: Fixture.external)
        #expect(summary.volumeGone)
        #expect(store.count == 1)
    }

    @Test func manyThreadsKeepBatchesInOrder() {
        let fs = Fixture.fileSystem()
        for i in 0..<30 { for j in 0..<5 { fs.addFile(data + home + "/p\(i)/q\(j)/f", size: 3) } }
        let (store, summary) = Fixture.scan(fs, volume: Fixture.startup, threads: 6)
        #expect(store.size(0) == 30 * 5 * 3)
        #expect(summary.files == 150)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}

@Suite struct VolumeTests {
    func mount(_ point: String, _ type: String = "apfs", local: Bool = true, readOnly: Bool = false, browse: Bool = true, used: UInt64 = 0,
               tm: Bool = false) -> MountRecord {
        MountRecord(mountPoint: point, fileSystemType: type, isLocal: local, isReadOnly: readOnly, isBrowsable: browse, usedBytes: used,
                    hasTimeMachineMarkers: tm)
    }

    @Test func classification() {
        let volumes = VolumeCatalogRules.volumes(from: [
            mount("/", readOnly: true, used: 13), mount("/System/Volumes/Data", used: 169), mount("/System/Volumes/VM", browse: false, used: 7),
            mount("/System/Volumes/Preboot", browse: false, used: 10), mount("/dev", "devfs"),
            mount("/System/Volumes/Data/home", "autofs", local: false), mount("/Volumes/Share", "smbfs", local: false),
            mount("/Volumes/NAS", "nfs", local: false), mount("/Volumes/Web", "webdav"), mount("/Volumes/Lexar", used: 63),
            mount("/Volumes/Backup", tm: true), mount("/Volumes/Win", "ntfs", readOnly: true), mount("/Volumes/Recovery", browse: false),
        ])
        #expect(volumes.map(\.mountPoint) == ["/", "/Volumes/Backup", "/Volumes/Lexar", "/Volumes/Win"])
        let startup = volumes[0]
        #expect(startup.scanRoot == "/System/Volumes/Data")
        #expect(startup.usedBytes == 169)
        #expect(startup.otherParts.map(\.name) == ["macOS system (sealed)", "VM swap", "Preboot", "Recovery"])
        #expect(volumes[1].kind == .timeMachine && !volumes[1].canTrash)
        #expect(volumes[2].canTrash)
        #expect(!volumes[3].canTrash)
    }

    @Test func firmlinkPaths() {
        let map = FirmlinkMap.parse("/Users\tUsers\n/Applications\tApplications\n/usr/local\tusr/local\nbad line\n")
        #expect(map.linked == ["Users", "Applications", "usr/local"])
        #expect(map.displayPath("/System/Volumes/Data/Users/a") == "/Users/a")
        #expect(map.displayPath("/System/Volumes/Data/usr/local/bin") == "/usr/local/bin")
        #expect(map.displayPath("/System/Volumes/Data/UsersX") == "/System/Volumes/Data/UsersX")
        #expect(map.displayPath("/System/Volumes/Data/MobileSoftwareUpdate") == "/System/Volumes/Data/MobileSoftwareUpdate")
    }

    @Test func trashLocations() {
        #expect(TrashLocation.folder(forMountPoint: "/", home: "/Users/t", userID: 501) == "/Users/t/.Trash")
        #expect(TrashLocation.folder(forMountPoint: "/Volumes/X", home: "/Users/t", userID: 501) == "/Volumes/X/.Trashes/501")
    }
}
