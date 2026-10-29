import Foundation
import Testing
@testable import MacCleanCore

/// A scanned machine with the effects wired to fakes.
struct Rig {
    let fs: FakeFileSystem
    let store: NodeStore
    let volume: Volume
    let trasher: FakeTrasher
    let admin: FakeAdmin
    let openFiles = FakeOpenFiles()
    let mounts = FakeMounts(Set(Fixture.volumes.map(\.mountPoint)))
    var lines: LogLines

    init(_ fs: FakeFileSystem, volume: Volume = Fixture.startup) {
        self.fs = fs
        self.volume = volume
        store = Fixture.scan(fs, volume: volume).0
        trasher = FakeTrasher(fs: fs, trashFolder: Fixture.trashFolder(volume.mountPoint))
        admin = FakeAdmin(fs: fs)
        lines = LogLines()
    }

    var policy: SafetyPolicy { Fixture.policy(fs) }

    func id(_ path: String) -> NodeID { store.find(path)! }

    func plan(_ paths: [String]) -> DeletionPlan {
        DeletionPlan.make(store: store, ticked: Set(paths.map(id)), policy: policy, volume: volume, userID: Fixture.uid)
    }

    var remover: Remover {
        let lines = self.lines
        return Remover(policy: policy, trasher: trasher, admin: admin, openFiles: openFiles, mounts: mounts,
                       log: ActionLog(append: { lines.add($0) }), trashFolder: { Fixture.trashFolder($0) })
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite struct PlanTests {
    let home = Fixture.home
    let data = Fixture.data

    func machine() -> FakeFileSystem {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/Downloads/a.dmg", size: 1000)
        fs.addFile(data + home + "/Downloads/b.zip", size: 2000)
        fs.addFile(data + home + "/Downloads/keep.pdf", size: 3000)
        fs.addFile(data + home + "/Projects/x/build/out.o", size: 10)
        fs.addFile(data + home + "/Library/Keychains/login.keychain-db", size: 10)
        return fs
    }

    @Test func onlyTickedItemsArePlanned() {
        let rig = Rig(machine())
        let plan = rig.plan([home + "/Downloads/a.dmg", home + "/Downloads/b.zip"])
        #expect(plan.items.map(\.path).sorted() == [home + "/Downloads/a.dmg", home + "/Downloads/b.zip"])
        #expect(plan.totalBytes == 3000)
        #expect(plan.rejected.isEmpty)
    }

    @Test func nothingTickedPlansNothing() {
        let rig = Rig(machine())
        let plan = DeletionPlan.make(store: rig.store, ticked: [], policy: rig.policy, volume: rig.volume, userID: Fixture.uid)
        #expect(plan.items.isEmpty)
    }

    @Test func rootAndUnknownIdsAreIgnored() {
        let rig = Rig(machine())
        let plan = DeletionPlan.make(store: rig.store, ticked: [0, 999_999], policy: rig.policy, volume: rig.volume, userID: Fixture.uid)
        #expect(plan.items.isEmpty && plan.rejected.isEmpty)
    }

    @Test func childOfATickedFolderIsNotPlannedTwice() {
        let rig = Rig(machine())
        let plan = rig.plan([home + "/Projects/x", home + "/Projects/x/build/out.o", home + "/Projects/x/build"])
        #expect(plan.items.map(\.path) == [home + "/Projects/x"])
    }

    @Test func protectedTicksAreRejectedWithAReason() {
        let rig = Rig(machine())
        let plan = rig.plan([home + "/Library/Keychains/login.keychain-db", home + "/Downloads"])
        #expect(plan.items.isEmpty)
        #expect(plan.rejected.count == 2)
    }

    @Test func itemThatChangedKindIsRejected() {
        let fs = machine()
        let rig = Rig(fs)
        let target = home + "/Downloads/a.dmg"
        fs.removeTree(data + target)
        fs.addDir(data + target)
        let plan = rig.plan([target])
        #expect(plan.items.isEmpty)
        #expect(plan.rejected.first?.reason == "changed since the scan")
    }

    @Test func rootOwnedItemsNeedAdministrator() {
        let fs = machine()
        fs.addFile(data + home + "/Downloads/root.pkg", size: 5, owner: 0)
        let rig = Rig(fs)
        let plan = rig.plan([home + "/Downloads/root.pkg", home + "/Downloads/a.dmg"])
        #expect(plan.adminItems.map(\.path) == [home + "/Downloads/root.pkg"])
        #expect(plan.userItems.map(\.path) == [home + "/Downloads/a.dmg"])
    }
}

@Suite struct RemoverTests {
    let home = Fixture.home
    let data = Fixture.data

    func machine() -> FakeFileSystem {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/Downloads/a.dmg", size: 1000)
        fs.addFile(data + home + "/Downloads/b.zip", size: 2000)
        fs.addFile("/Volumes/Ext/old.mov", size: 50)
        return fs
    }

    @Test func movesTheItemsAndLogsThem() {
        let rig = Rig(machine())
        let outcomes = rig.remover.execute(rig.plan([home + "/Downloads/a.dmg"]), includeAdmin: false)
        guard case .trashed(let record)? = outcomes.first?.status else { Issue.record("not trashed"); return }
        #expect(record.trashed == home + "/.Trash/a.dmg")
        #expect(rig.trasher.calls == [home + "/Downloads/a.dmg"])
        #expect(rig.fs.has(home + "/Downloads/b.zip"))
        #expect(rig.lines.all.count == 1)
    }

    @Test func replacedItemIsSkipped() {
        let rig = Rig(machine())
        let plan = rig.plan([home + "/Downloads/a.dmg"])
        rig.fs.replaceWithNewObject(home + "/Downloads/a.dmg")
        let outcomes = rig.remover.execute(plan, includeAdmin: false)
        #expect(outcomes.first?.status == .skipped("changed since the scan"))
        #expect(rig.trasher.calls.isEmpty)
    }

    @Test func linkSwappedInAfterPlanningIsSkipped() {
        let fs = machine()
        fs.addFile(data + home + "/Work/tmp/file", size: 1)
        let rig = Rig(fs)
        let plan = rig.plan([home + "/Work/tmp/file"])
        // Replace the parent folder with a link to somewhere else that has a file of the same name.
        fs.removeTree(home + "/Work/tmp")
        fs.addFile("/System/Library/file", size: 1)
        fs.addSymlink(data + home + "/Work/tmp", to: "/System/Library")
        let outcomes = rig.remover.execute(plan, includeAdmin: false)
        guard case .skipped? = outcomes.first?.status else { Issue.record("not skipped"); return }
        #expect(rig.trasher.calls.isEmpty)
        #expect(fs.has("/System/Library/file"))
    }

    @Test func itemInUseIsSkipped() {
        let rig = Rig(machine())
        rig.openFiles.open[home + "/Downloads/a.dmg"] = "DiskImageMounter"
        let outcomes = rig.remover.execute(rig.plan([home + "/Downloads/a.dmg"]), includeAdmin: false)
        #expect(outcomes.first?.status == .skipped("in use by DiskImageMounter"))
        #expect(rig.trasher.calls.isEmpty)
    }

    @Test func folderWithAnOpenFileInsideIsSkipped() {
        let fs = machine()
        fs.addFile(data + home + "/Work/proj/db.sqlite", size: 1)
        let rig = Rig(fs)
        rig.openFiles.open[home + "/Work/proj/db.sqlite"] = "Xcode"
        let outcomes = rig.remover.execute(rig.plan([home + "/Work/proj"]), includeAdmin: false)
        #expect(outcomes.first?.status == .skipped("in use by Xcode"))
    }

    @Test func unpluggedVolumeIsSkipped() {
        let rig = Rig(machine(), volume: Fixture.external)
        let plan = rig.plan(["/Volumes/Ext/old.mov"])
        rig.mounts.mounted.remove("/Volumes/Ext")
        let outcomes = rig.remover.execute(plan, includeAdmin: false)
        #expect(outcomes.first?.status == .skipped("the volume is no longer connected"))
        #expect(rig.trasher.calls.isEmpty)
    }

    @Test func policyIsCheckedAgainAtExecution() {
        let rig = Rig(machine())
        let plan = rig.plan([home + "/Downloads/a.dmg"])
        var remover = rig.remover
        remover.policy.volumes = remover.policy.volumes.map { var v = $0; if v.kind == .startupData { v.isReadOnly = true }; return v }
        let outcomes = remover.execute(plan, includeAdmin: false)
        #expect(outcomes.first?.status == .skipped("volume is read-only"))
    }

    @Test func fatFilesMustKeepSizeAndDate() {
        let fs = Fixture.fileSystem()
        fs.addFile("/Volumes/Stick/a.mov", size: 100)
        fs.addFile("/Volumes/Stick/b.mov", size: 100)
        let rig = Rig(fs, volume: Fixture.fat)
        let plan = rig.plan(["/Volumes/Stick/a.mov", "/Volumes/Stick/b.mov"])
        fs.touch("/Volumes/Stick/a.mov", size: 200)
        let outcomes = rig.remover.execute(plan, includeAdmin: false)
        #expect(outcomes.first { $0.path == "/Volumes/Stick/a.mov" }?.status == .skipped("changed since the scan"))
        #expect(rig.trasher.calls == ["/Volumes/Stick/b.mov"])
    }

    @Test func externalItemsGoToThatVolumesTrash() {
        let fs = machine()
        fs.addFile("/Volumes/Ext/root-owned.bin", size: 5, owner: 0)
        let rig = Rig(fs, volume: Fixture.external)
        let outcomes = rig.remover.execute(rig.plan(["/Volumes/Ext/root-owned.bin"]), includeAdmin: true)
        #expect(rig.admin.performed.first?.trashFolder == "/Volumes/Ext/.Trashes/501")
        guard case .trashed? = outcomes.first?.status else { Issue.record("not trashed"); return }
    }

    @Test func administratorItemsNeedConsent() {
        let fs = machine()
        fs.addFile(data + home + "/Downloads/root.pkg", size: 5, owner: 0)
        let rig = Rig(fs)
        let plan = rig.plan([home + "/Downloads/root.pkg"])
        let outcomes = rig.remover.execute(plan, includeAdmin: false)
        #expect(outcomes.first?.status == .skipped("needs administrator"))
        #expect(rig.admin.performed.isEmpty)
        _ = rig.remover.execute(plan, includeAdmin: true)
        #expect(rig.admin.performed.first?.paths == [home + "/Downloads/root.pkg"])
    }

    @Test func oneFailureDoesNotStopTheRest() {
        let rig = Rig(machine())
        rig.trasher.failing.insert(home + "/Downloads/a.dmg")
        let outcomes = rig.remover.execute(rig.plan([home + "/Downloads/a.dmg", home + "/Downloads/b.zip"]), includeAdmin: false)
        #expect(outcomes.count == 2)
        #expect(rig.trasher.calls.count == 2)
    }
}

@Suite struct PermanentDeleterTests {
    let home = Fixture.home

    func deleter(_ fs: FakeFileSystem, admin: FakeAdmin? = nil) -> (PermanentDeleter, FakeRemover) {
        let remover = FakeRemover(fs: fs)
        return (PermanentDeleter(fileSystem: fs, remover: remover, admin: admin, userID: Fixture.uid,
                                 trashFolders: [home + "/.Trash", "/Volumes/Ext/.Trashes/501"]), remover)
    }

    func record(_ fs: FakeFileSystem, _ path: String) -> TrashRecord {
        let info = try! fs.info(path)
        return TrashRecord(original: "/x", trashed: path, device: info.device, inode: info.inode, bytes: 1)
    }

    @Test func deletesWhatIsDirectlyInTheTrash() {
        let fs = Fixture.fileSystem()
        fs.addFile(home + "/.Trash/a.dmg")
        let (d, remover) = deleter(fs)
        let outcomes = d.delete([record(fs, home + "/.Trash/a.dmg")])
        #expect(outcomes.first?.error == nil)
        #expect(remover.calls == [home + "/.Trash/a.dmg"])
    }

    @Test func refusesAnythingElse() {
        let fs = Fixture.fileSystem()
        fs.addFile(home + "/Downloads/a.dmg")
        fs.addFile(home + "/.Trash/folder/inner")
        let (d, remover) = deleter(fs)
        let outcomes = d.delete([record(fs, home + "/Downloads/a.dmg"), record(fs, home + "/.Trash/folder/inner"),
                                 TrashRecord(original: "/x", trashed: home + "/.Trash", device: 2, inode: 1, bytes: 0)])
        #expect(outcomes.allSatisfy { $0.error == "not in the Trash" })
        #expect(remover.calls.isEmpty)
    }

    @Test func refusesAReplacedItem() {
        let fs = Fixture.fileSystem()
        fs.addFile(home + "/.Trash/a.dmg")
        let r = record(fs, home + "/.Trash/a.dmg")
        fs.replaceWithNewObject(home + "/.Trash/a.dmg")
        let (d, remover) = deleter(fs)
        #expect(d.delete([r]).first?.error == "the item in the Trash has changed")
        #expect(remover.calls.isEmpty)
    }

    @Test func rootOwnedTrashItemsGoThroughTheAdministrator() {
        let fs = Fixture.fileSystem()
        fs.addFile(home + "/.Trash/root.pkg", owner: 0)
        let admin = FakeAdmin(fs: fs)
        let (d, remover) = deleter(fs, admin: admin)
        _ = d.delete([record(fs, home + "/.Trash/root.pkg")])
        #expect(remover.calls.isEmpty)
        #expect(admin.removed == [home + "/.Trash/root.pkg"])
    }
}

@Suite struct AdminScriptTests {
    @Test func quotesEveryPath() {
        #expect(AdminScript.quote("a'b") == "'a'\\''b'")
        let item = PlannedItem(path: "/Users/t/x'; rm -rf ~; '", device: 1, inode: 1, type: .regular, size: 0, modified: .distantPast,
                               checkSizeAndDate: false, bytes: 0, ownership: .administrator)
        let script = AdminScript.build([item], trashFolder: "/Users/t/.Trash", stamp: "1")
        #expect(script.contains("'/Users/t/x'\\''; rm -rf ~; '\\'''"))
        #expect(!script.contains("x'; rm"))
        let removal = AdminScript.buildRemoval(["/Users/t/.Trash/a'b"])
        #expect(removal.contains("'/Users/t/.Trash/a'\\''b'"))
    }

    @Test func dropsPathsWithLineBreaks() {
        #expect(AdminScript.buildRemoval(["/a\nb"]) == "set -u")
    }

    @Test func parsesResults() {
        let results = AdminScript.parse("OK\t/a\t/T/a\nERR\t/b\n", keys: ["/a", "/b", "/c"])
        #expect(results["/a"] == .success("/T/a"))
        #expect(results["/b"] == .failure(AdminError("failed")))
        #expect(results["/c"] == .failure(AdminError("not done")))
    }
}
