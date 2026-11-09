import Foundation
import Testing
@testable import UninstallCore

@Suite struct SafetyPolicyTests {
    let home = Fixture.home
    var lib: String { home + "/Library" }

    func denied(_ path: String, _ fs: FakeFileSystem) -> Bool {
        if case .denied = Fixture.policy(fs).check(path) { return true }
        return false
    }

    @Test func ordinaryLeftoversAreAllowed() {
        let fs = Fixture.fileSystem()
        fs.addDir(lib + "/Caches/com.gone.App")
        fs.addDir("/Applications/Foo.app")
        fs.addDir("/Applications/Utilities/Bar.app")
        fs.addDir(lib + "/Application Support/Google/Chrome")
        fs.addFile("/Library/LaunchDaemons/com.docker.vmnetd.plist")
        #expect(Fixture.policy(fs).check(lib + "/Caches/com.gone.App") == .allowed)
        #expect(Fixture.policy(fs).check("/Applications/Foo.app") == .allowed)
        #expect(Fixture.policy(fs).check("/Applications/Utilities/Bar.app") == .allowed)
        #expect(Fixture.policy(fs).check(lib + "/Application Support/Google/Chrome") == .allowed)
        #expect(Fixture.policy(fs).check("/Library/LaunchDaemons/com.docker.vmnetd.plist") == .allowed)
    }

    @Test(arguments: [
        "/", "/System", "/Users", "/Applications", "/Library", "/usr/bin", "/private/var/db/receipts",
        "/Users/tester", "/Users/tester/Documents", "/Users/tester/Desktop", "/Users/tester/Downloads",
        "/Users/tester/Library", "/Users/tester/Library/Caches", "/Users/tester/Library/Application Support",
        "/Users/tester/Library/Keychains/login.keychain-db", "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs",
        "/Users/tester/.Trash/old", "/Library/LaunchDaemons",
    ])
    func protectedPlacesAreDenied(_ path: String) {
        let fs = Fixture.fileSystem()
        fs.addDir(path)
        #expect(denied(path, fs))
    }

    @Test(arguments: [
        "Users/tester/Library/Caches/x", "/Users/tester/Library/Caches/../../Documents",
        "/Users/tester/Library/Caches/./x", "/Users/tester/Library/Caches//x", "/Users/tester/Library/Caches/x/",
        "/Users/tester/Library/Caches/a\nb",
    ])
    func malformedPathsAreDenied(_ path: String) {
        let fs = Fixture.fileSystem()
        fs.addDir(path)
        #expect(denied(path, fs))
    }

    @Test func outsideTheCleanedFoldersIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addDir(home + "/Projects/thing")
        fs.addDir(home + "/Documents/com.gone.App")
        fs.addDir("/opt/homebrew/Cellar/x")
        #expect(denied(home + "/Projects/thing", fs))
        #expect(denied(home + "/Documents/com.gone.App", fs))
        #expect(denied("/opt/homebrew/Cellar/x", fs))
    }

    @Test func pathThroughASymlinkedFolderIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addDir(home + "/Documents/secret")
        fs.addSymlink(lib + "/Caches/evil", to: home + "/Documents")
        #expect(Fixture.policy(fs).check(lib + "/Caches/evil/secret") == .denied("path goes through a symbolic link (\(home)/Documents)"))
        fs.addDir(lib + "/Caches/real/x")
        fs.addSymlink(lib + "/Caches/alias", to: lib + "/Caches/real")
        #expect(denied(lib + "/Caches/alias/x", fs))
    }

    @Test func aSymlinkItselfIsAllowedAsALink() {
        let fs = Fixture.fileSystem()
        fs.addSymlink(lib + "/Caches/com.gone.link", to: home + "/Documents")
        #expect(Fixture.policy(fs).check(lib + "/Caches/com.gone.link") == .allowed)
    }

    @Test func appleAndSelfAreDenied() {
        let fs = Fixture.fileSystem()
        fs.addFile(lib + "/Preferences/com.apple.finder.plist")
        fs.addDir(lib + "/Group Containers/group.com.apple.notes")
        fs.addDir("/Applications/Mac Clean.app")
        fs.addFile(lib + "/Preferences/com.dat98it.MacClean.plist")
        fs.addDir(lib + "/Application Support/com.dat98it.MacClean")
        for path in [lib + "/Preferences/com.apple.finder.plist", lib + "/Group Containers/group.com.apple.notes",
                     "/Applications/Mac Clean.app", lib + "/Preferences/com.dat98it.MacClean.plist",
                     lib + "/Application Support/com.dat98it.MacClean"] {
            #expect(denied(path, fs), "\(path)")
        }
    }

    @Test func appInsideAnotherAppIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addDir("/Applications/Big.app/Contents/Helpers/Helper.app")
        #expect(denied("/Applications/Big.app/Contents/Helpers/Helper.app", fs))
    }

    /// Each protective layer must hold on its own, even if the cleaned folders were set up wrongly.
    func misconfigured(_ fs: FakeFileSystem) -> SafetyPolicy {
        SafetyPolicy(fileSystem: fs, home: home, dataRoots: ["/"], appRoots: ["/"])
    }

    @Test func protectedFoldersHoldEvenWithMisconfiguredRoots() {
        let fs = Fixture.fileSystem()
        fs.addDir(home + "/Documents")
        #expect(misconfigured(fs).check(home + "/Documents") != .allowed)
    }

    @Test func protectedTreesHoldEvenWithMisconfiguredRoots() {
        let fs = Fixture.fileSystem()
        fs.addFile(lib + "/Keychains/login.keychain-db")
        #expect(misconfigured(fs).check(lib + "/Keychains/login.keychain-db") != .allowed)
    }

    @Test func folderContainingAProtectedOneIsDeniedEvenWithMisconfiguredRoots() {
        let fs = Fixture.fileSystem()
        fs.addDir("/private/var/db/receipts")
        #expect(misconfigured(fs).check("/private/var") != .allowed)
    }

    @Test func appleDataIsDeniedEvenWithMisconfiguredRoots() {
        let fs = Fixture.fileSystem()
        fs.addFile(lib + "/Preferences/com.apple.finder.plist")
        #expect(misconfigured(fs).check(lib + "/Preferences/com.apple.finder.plist") != .allowed)
    }

    @Test func missingPathIsDenied() {
        #expect(denied(lib + "/Caches/nothing", Fixture.fileSystem()))
    }
}

@Suite struct DeletionPlanTests {
    let lib = Fixture.home + "/Library"

    func finding(_ path: String, _ kind: DataKind = .cache, domain: Domain = .user) -> Finding {
        Finding(path: path, kind: kind, domain: domain, confidence: .high, reason: .bundleID("x"))
    }

    @Test func onlyTickedFindingsArePlanned() {
        let fs = Fixture.fileSystem()
        fs.addDir(lib + "/Caches/a").addDir(lib + "/Caches/b").addDir(lib + "/Caches/c")
        let findings = ["a", "b", "c"].map { finding(lib + "/Caches/\($0)") }
        let plan = DeletionPlan.make(findings: findings, selected: [lib + "/Caches/b"], sizes: [:], policy: Fixture.policy(fs))
        #expect(plan.items.map(\.displayPath) == [lib + "/Caches/b"])
    }

    @Test func selectedPathThatIsNotAFindingIsNeverPlanned() {
        let fs = Fixture.fileSystem()
        fs.addDir(lib + "/Caches/a").addDir(lib + "/Caches/intruder")
        let plan = DeletionPlan.make(findings: [finding(lib + "/Caches/a")],
                                     selected: [lib + "/Caches/a", lib + "/Caches/intruder"], sizes: [:], policy: Fixture.policy(fs))
        #expect(plan.items.map(\.displayPath) == [lib + "/Caches/a"])
    }

    @Test func nothingTickedMeansAnEmptyPlan() {
        let fs = Fixture.fileSystem()
        fs.addDir(lib + "/Caches/a")
        #expect(DeletionPlan.make(findings: [finding(lib + "/Caches/a")], selected: [], sizes: [:], policy: Fixture.policy(fs)).items.isEmpty)
    }

    @Test func deniedFindingsAreRejectedWithAReason() {
        let fs = Fixture.fileSystem()
        let plan = DeletionPlan.make(findings: [finding(Fixture.home + "/Documents")], selected: [Fixture.home + "/Documents"],
                                     sizes: [:], policy: Fixture.policy(fs))
        #expect(plan.items.isEmpty)
        #expect(plan.rejected.count == 1)
    }

    @Test func childrenOfAPlannedFolderAreNotPlannedTwice() {
        let fs = Fixture.fileSystem()
        fs.addDir(lib + "/Application Support/Google/Chrome")
        fs.addDir(lib + "/Application Support/Foo/Sub")
        let findings = [finding(lib + "/Application Support/Foo"), finding(lib + "/Application Support/Foo/Sub")]
        let plan = DeletionPlan.make(findings: findings, selected: Set(findings.map(\.path)), sizes: [:], policy: Fixture.policy(fs))
        #expect(plan.items.map(\.displayPath) == [lib + "/Application Support/Foo"])
    }

    @Test func receiptsNeedAdminAndAValidIdentifier() {
        let fs = Fixture.fileSystem()
        let good = Finding(path: "pkgutil:com.acme.pkg", kind: .receipt, domain: .system, confidence: .high, reason: .receipt("x"))
        let bad = Finding(path: "pkgutil:com.acme; rm -rf ~", kind: .receipt, domain: .system, confidence: .high, reason: .receipt("x"))
        let plan = DeletionPlan.make(findings: [good, bad], selected: [good.path, bad.path], sizes: [:], policy: Fixture.policy(fs))
        #expect(plan.items.map(\.displayPath) == ["pkgutil:com.acme.pkg"])
        #expect(plan.items[0].needsAdmin)
        #expect(plan.rejected.map(\.path) == [bad.path])
    }
}

@Suite struct RemoverTests {
    let lib = Fixture.home + "/Library"
    var trashFolder: String { Fixture.home + "/.Trash" }

    func setup() -> (FakeFileSystem, FakeTrasher, Remover, LogCollector) {
        let fs = Fixture.fileSystem()
        let trasher = FakeTrasher(fs: fs, trashFolder: trashFolder)
        let logs = LogCollector()
        let remover = Remover(policy: Fixture.policy(fs), trasher: trasher, admin: FakeAdmin(fs: fs), log: logs.log, trashFolder: trashFolder)
        return (fs, trasher, remover, logs)
    }

    func plan(_ fs: FakeFileSystem, _ paths: [String], selected: [String]? = nil, domain: Domain = .user) -> DeletionPlan {
        let findings = paths.map { Finding(path: $0, kind: .cache, domain: domain, confidence: .high, reason: .bundleID("x")) }
        return DeletionPlan.make(findings: findings, selected: Set(selected ?? paths), sizes: [:], policy: Fixture.policy(fs))
    }

    @Test func trashesExactlyThePlannedItemsAndRecordsWhereTheyWent() {
        let (fs, trasher, remover, logs) = setup()
        fs.addDir(lib + "/Caches/a").addDir(lib + "/Caches/b").addDir(lib + "/Caches/keep")
        let outcomes = remover.execute(plan(fs, [lib + "/Caches/a", lib + "/Caches/b", lib + "/Caches/keep"],
                                            selected: [lib + "/Caches/a", lib + "/Caches/b"]), includeAdmin: false)
        #expect(trasher.calls == [lib + "/Caches/a", lib + "/Caches/b"])
        #expect(fs.exists(lib + "/Caches/keep"))
        #expect(outcomes.allSatisfy { if case .trashed(let r) = $0.status { return r.trashed.hasPrefix(trashFolder + "/") } else { return false } })
        #expect(logs.lines.count == 2)
    }

    @Test func itemReplacedSinceTheScanIsSkipped() {
        let (fs, trasher, remover, _) = setup()
        fs.addDir(lib + "/Caches/a")
        let p = plan(fs, [lib + "/Caches/a"])
        fs.replaceWithNewObject(lib + "/Caches/a")
        let outcomes = remover.execute(p, includeAdmin: false)
        #expect(trasher.calls.isEmpty)
        #expect(outcomes.first?.status == .skipped("changed since the scan"))
    }

    @Test func folderTurnedIntoASymlinkedPathIsSkipped() {
        let (fs, trasher, remover, _) = setup()
        fs.addDir(lib + "/Caches/vendor/a")
        let p = plan(fs, [lib + "/Caches/vendor/a"])
        fs.removeTree(lib + "/Caches/vendor")
        fs.addDir(Fixture.home + "/Documents/a")
        fs.addSymlink(lib + "/Caches/vendor", to: Fixture.home + "/Documents")
        _ = remover.execute(p, includeAdmin: false)
        #expect(trasher.calls.isEmpty)
        #expect(fs.exists(Fixture.home + "/Documents/a"))
    }

    @Test func oneFailureDoesNotStopTheRest() {
        let (fs, trasher, remover, _) = setup()
        fs.addDir(lib + "/Caches/a").addDir(lib + "/Caches/b")
        trasher.failing = [lib + "/Caches/a"]
        let outcomes = remover.execute(plan(fs, [lib + "/Caches/a", lib + "/Caches/b"]), includeAdmin: false)
        #expect(trasher.calls == [lib + "/Caches/a", lib + "/Caches/b"])
        #expect(outcomes.filter { if case .failed = $0.status { true } else { false } }.count == 1)
        #expect(!fs.exists(lib + "/Caches/b"))
    }

    @Test func adminItemsWaitForConsentAndRunInOneBatch() {
        let fs = Fixture.fileSystem()
        let admin = FakeAdmin(fs: fs)
        let remover = Remover(policy: Fixture.policy(fs), trasher: FakeTrasher(fs: fs, trashFolder: trashFolder), admin: admin,
                              trashFolder: trashFolder)
        fs.addFile("/Library/LaunchDaemons/com.x.d.plist").addFile("/Library/PrivilegedHelperTools/com.x.d")
        let p = plan(fs, ["/Library/LaunchDaemons/com.x.d.plist", "/Library/PrivilegedHelperTools/com.x.d"], domain: .system)
        let skipped = remover.execute(p, includeAdmin: false)
        #expect(admin.batches.isEmpty)
        #expect(skipped.allSatisfy { $0.status == .skipped("needs administrator") })
        _ = remover.execute(p, includeAdmin: true)
        #expect(admin.batches.count == 1)
        #expect(admin.batches[0].count == 2)
    }
}

@Suite struct PermanentDeleterTests {
    let trash = Fixture.home + "/.Trash"

    func trashed(_ fs: FakeFileSystem, _ name: String, owner: UInt32? = nil) -> TrashRecord {
        let original = Fixture.home + "/Library/Caches/" + name
        fs.addDir(original, owner: owner)
        let info = try! fs.info(original)
        let destination = try! FakeTrasher(fs: fs, trashFolder: trash).trash(original)
        return TrashRecord(original: original, trashed: destination, device: info.device, inode: info.inode, bytes: 10)
    }

    @Test func deletesOnlyTheGivenTrashedItems() {
        let fs = Fixture.fileSystem()
        let a = trashed(fs, "a")
        _ = trashed(fs, "users-other-trash")
        let remover = FakeRemover(fs: fs)
        let out = PermanentDeleter(fileSystem: fs, remover: remover, trashFolders: [trash]).delete([a])
        #expect(out.map(\.error) == [nil])
        #expect(remover.calls == [a.trashed])
        #expect(fs.exists(trash + "/users-other-trash"))
    }

    @Test func refusesAnythingOutsideTheTrash() {
        let fs = Fixture.fileSystem()
        fs.addDir(Fixture.home + "/Documents/x")
        let info = try! fs.info(Fixture.home + "/Documents/x")
        let forged = TrashRecord(original: "", trashed: Fixture.home + "/Documents/x", device: info.device, inode: info.inode, bytes: 0)
        let remover = FakeRemover(fs: fs)
        let out = PermanentDeleter(fileSystem: fs, remover: remover, trashFolders: [trash]).delete([forged])
        #expect(out[0].error == "not in the Trash")
        #expect(remover.calls.isEmpty)
    }

    @Test func refusesTheTrashFolderItselfAndDeeperPaths() {
        let fs = Fixture.fileSystem()
        let a = trashed(fs, "a")
        fs.addDir(a.trashed + "/inner")
        let remover = FakeRemover(fs: fs)
        let deleter = PermanentDeleter(fileSystem: fs, remover: remover, trashFolders: [trash])
        var root = a
        root.trashed = trash
        var inner = a
        inner.trashed = a.trashed + "/inner"
        _ = deleter.delete([root, inner])
        #expect(remover.calls.isEmpty)
    }

    @Test func itemsOwnedBySomeoneElseGoThroughTheAdministratorInOneBatch() {
        // An App Store app moved to the Trash with a password still belongs to root.
        let fs = Fixture.fileSystem()
        let mine = trashed(fs, "mine", owner: 501)
        let roots = trashed(fs, "roots", owner: 0)
        let roots2 = trashed(fs, "roots2", owner: 0)
        let remover = FakeRemover(fs: fs)
        let admin = FakeAdminRemover(fs: fs)
        let deleter = PermanentDeleter(fileSystem: fs, remover: remover, admin: admin, userID: 501, trashFolders: [trash])
        #expect(deleter.needingAdmin([mine, roots, roots2]).map(\.trashed) == [roots.trashed, roots2.trashed])
        let out = deleter.delete([mine, roots, roots2])
        #expect(out.map(\.error) == [nil, nil, nil])
        #expect(remover.calls == [mine.trashed])
        #expect(admin.calls == [[roots.trashed, roots2.trashed]])
    }

    @Test func withoutAnAdministratorRootItemsAreLeftAlone() {
        let fs = Fixture.fileSystem()
        let roots = trashed(fs, "roots", owner: 0)
        let remover = FakeRemover(fs: fs)
        let out = PermanentDeleter(fileSystem: fs, remover: remover, userID: 501, trashFolders: [trash]).delete([roots])
        #expect(out[0].error == "needs administrator")
        #expect(remover.calls.isEmpty)
    }

    @Test func theAdministratorNeverGetsAnUncheckedPath() {
        let fs = Fixture.fileSystem()
        fs.addDir(Fixture.home + "/Documents/x", owner: 0)
        let info = try! fs.info(Fixture.home + "/Documents/x")
        let forged = TrashRecord(original: "", trashed: Fixture.home + "/Documents/x", device: info.device, inode: info.inode, bytes: 0)
        let admin = FakeAdminRemover(fs: fs)
        _ = PermanentDeleter(fileSystem: fs, remover: FakeRemover(fs: fs), admin: admin, userID: 501, trashFolders: [trash]).delete([forged])
        #expect(admin.calls.isEmpty)
    }

    @Test func refusesAnItemThatChangedInTheTrash() {
        let fs = Fixture.fileSystem()
        let a = trashed(fs, "a")
        fs.replaceWithNewObject(a.trashed)
        let remover = FakeRemover(fs: fs)
        let out = PermanentDeleter(fileSystem: fs, remover: remover, trashFolders: [trash]).delete([a])
        #expect(out[0].error == "the item in the Trash has changed")
        #expect(remover.calls.isEmpty)
    }
}

@Suite struct AdminScriptTests {
    @Test func everyPathIsSingleQuoted() {
        let item = PlannedItem(target: .path("/Library/Application Support/it's $(evil)", device: 1, inode: 2, type: .directory),
                               kind: .userData, domain: .system, bytes: 0)
        let script = AdminScript.build([item], trashFolder: "/Users/t/.Trash", stamp: "1")
        #expect(script.contains("'/Library/Application Support/it'\\''s $(evil)'"))
        #expect(!script.contains(" /Library/Application Support/it's"))
    }

    @Test func daemonsAreUnloadedBeforeMoving() {
        let item = PlannedItem(target: .path("/Library/LaunchDaemons/com.x.plist", device: 1, inode: 2, type: .regular),
                               kind: .launchItem, domain: .system, bytes: 0)
        let lines = AdminScript.build([item], trashFolder: "/Users/t/.Trash", stamp: "1").split(separator: "\n")
        #expect(lines[1].contains("launchctl bootout system"))
        #expect(lines[2].contains("/bin/mv -n"))
    }

    @Test func removalQuotesEveryPath() {
        let script = AdminScript.buildRemoval(["/Users/t/.Trash/it's $(evil)", "/Users/t/.Trash/bad\nname"])
        #expect(script.contains("/bin/rm -rf -- '/Users/t/.Trash/it'\\''s $(evil)'"))
        #expect(!script.contains("bad"))
    }

    @Test func movedItemsKeepTheirExtension() {
        #expect(AdminScript.uniqueName("Microsoft PowerPoint.app", stamp: "17", index: 0) == "Microsoft PowerPoint 17-0.app")
        #expect(AdminScript.uniqueName("com.x.helper", stamp: "17", index: 2) == "com.x 17-2.helper")
        #expect(AdminScript.uniqueName("vmnetd", stamp: "17", index: 1) == "vmnetd 17-1")
    }

    @Test func outputIsParsedBackAndMissingLinesAreFailures() {
        let a = PlannedItem(target: .path("/Library/A", device: 1, inode: 2, type: .directory), kind: .userData, domain: .system, bytes: 0)
        let b = PlannedItem(target: .path("/Library/B", device: 1, inode: 3, type: .directory), kind: .userData, domain: .system, bytes: 0)
        let r = AdminScript.parse("OK\t/Library/A\t/Users/t/.Trash/A 1-0\n", items: [a, b])
        #expect(r["/Library/A"] == .success("/Users/t/.Trash/A 1-0"))
        #expect(r["/Library/B"] == .failure(AdminError("not done")))
    }
}

@Suite struct SizeCalculatorTests {
    @Test func hardLinksCountOnceClonesByPrivateSizeSymlinksNotFollowed() {
        let fs = FakeFileSystem()
        fs.addFile("/d/a", size: 1000, inode: 50, linkCount: 2)
        fs.addFile("/d/b", size: 1000, inode: 50, linkCount: 2)
        fs.addFile("/d/clone", size: 4000, privateSize: 0)
        fs.addFile("/big/x", size: 99_999)
        fs.addSymlink("/d/link", to: "/big")
        var seen = Set<[UInt64]>()
        let totals = SizeCalculator(fileSystem: fs).size(of: ["/d"], seen: &seen)
        #expect(totals.bytes == 1000)
        #expect(totals.naiveBytes == 6000)
    }
}

@Suite struct IgnoreListTests {
    @Test func roundTripsAndIgnoresCase() {
        var list = IgnoreList()
        list.add("Com.Gone.App")
        let back = IgnoreList.decode(list.encoded())
        #expect(back.contains("com.gone.app"))
        #expect(IgnoreList.decode(Data("garbage".utf8)).keys.isEmpty)
    }
}
