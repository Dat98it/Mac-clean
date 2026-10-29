import Foundation
import Testing
@testable import MacCleanCore

@Suite struct BrowseTests {
    let home = Fixture.home
    let data = Fixture.data

    func store() -> NodeStore {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/D/file10.txt", size: 300, modified: Date(timeIntervalSince1970: 3_000_000), birth: 30)
        fs.addFile(data + home + "/D/file2.txt", size: 100, modified: Date(timeIntervalSince1970: 2_000_000), birth: 10)
        fs.addFile(data + home + "/D/Tài liệu.pdf", size: 200, modified: Date(timeIntervalSince1970: 1_000_000), birth: 20)
        fs.addFile(data + home + "/D/sub/deep.mov", size: 50, modified: Date(timeIntervalSince1970: 500_000))
        return Fixture.scan(fs, volume: Fixture.startup).0
    }

    func names(_ s: NodeStore, _ ids: [NodeID]) -> [String] { ids.map { s.name($0) } }

    @Test func sortsLikeFinder() {
        let s = store()
        let d = s.find(home + "/D")!
        #expect(names(s, Browse.children(of: d, in: s, order: SortOrder(column: .name, ascending: true), filter: .init()))
                == ["file2.txt", "file10.txt", "sub", "Tài liệu.pdf"])
        #expect(names(s, Browse.children(of: d, in: s, order: .default, filter: .init()))
                == ["file10.txt", "Tài liệu.pdf", "file2.txt", "sub"])
        #expect(names(s, Browse.children(of: d, in: s, order: SortOrder(column: .created, ascending: true), filter: .init())).prefix(3)
                == ["file2.txt", "Tài liệu.pdf", "file10.txt"])
        #expect(names(s, Browse.children(of: d, in: s, order: SortOrder(column: .modified, ascending: false), filter: .init())).first
                == "file10.txt")
        #expect(names(s, Browse.children(of: d, in: s, order: SortOrder(column: .kind, ascending: true), filter: .init())).first == "sub")
    }

    @Test func minimumSizeHidesSmallItems() {
        let s = store()
        let d = s.find(home + "/D")!
        #expect(names(s, Browse.children(of: d, in: s, order: .default, filter: BrowseFilter(minimumSize: 150)))
                == ["file10.txt", "Tài liệu.pdf"])
    }

    @Test func nameFilterIgnoresCaseAndAccents() {
        let s = store()
        let (ids, truncated) = Browse.matches(in: s, filter: BrowseFilter(name: "TAI LIEU"), order: .default, now: Date())
        #expect(names(s, ids) == ["Tài liệu.pdf"])
        #expect(!truncated)
    }

    @Test func ageFilterUsesModificationDate() {
        let s = store()
        let now = Date(timeIntervalSince1970: 2_000_000 + 86_400 * 10)
        let (ids, _) = Browse.matches(in: s, filter: BrowseFilter(minimumSize: 1, minimumAgeDays: 20), order: .default, now: now)
        #expect(Set(names(s, ids)).isSuperset(of: ["Tài liệu.pdf", "deep.mov"]))
        #expect(!names(s, ids).contains("file10.txt"))
        #expect(!names(s, ids).contains("file2.txt"))
    }

    @Test func matchesAreCapped() {
        let s = store()
        let (ids, truncated) = Browse.matches(in: s, filter: BrowseFilter(name: "file"), order: .default, now: Date(), limit: 1)
        #expect(names(s, ids) == ["file10.txt"])
        #expect(truncated)
    }

    @Test func storeRejectsBatchesOutOfOrder() {
        let s = NodeStore(rootPath: "/Volumes/X")
        #expect(!s.apply(ScanBatch(parent: 0, firstID: 5, records: [NodeRecord(name: "a", kind: .file)])))
        #expect(!s.apply(ScanBatch(parent: 9, firstID: 1, records: [NodeRecord(name: "a", kind: .file)])))
        #expect(s.apply(ScanBatch(parent: 0, firstID: 1, records: [NodeRecord(name: "a", kind: .file, allocated: 4)])))
        #expect(s.size(0) == 4 && s.count == 2)
    }
}

@Suite struct SuggestionTests {
    let home = Fixture.home
    let data = Fixture.data
    let now = Date(timeIntervalSince1970: 200 * 86_400)

    func store() -> NodeStore {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/Library/Caches/com.big.App/blob", size: 5_000_000)
        fs.addFile(data + home + "/Library/Caches/com.tiny.App/blob", size: 10)
        fs.addFile(data + home + "/Library/Developer/Xcode/DerivedData/Proj-abc/Build/x", size: 2_000_000)
        fs.addFile(data + home + "/Library/Developer/CoreSimulator/Devices/UUID-1/data/x", size: 3_000_000)
        fs.addFile(data + home + "/Library/Application Support/MobileSync/Backup/00008-ABC/Manifest.db", size: 4_000_000)
        fs.addFile(data + home + "/Downloads/old.iso", size: 200_000_000, modified: Date(timeIntervalSince1970: 10 * 86_400))
        fs.addFile(data + home + "/Downloads/nested/old.zip", size: 150_000_000, modified: Date(timeIntervalSince1970: 10 * 86_400))
        fs.addFile(data + home + "/Downloads/new.iso", size: 200_000_000, modified: Date(timeIntervalSince1970: 190 * 86_400))
        fs.addFile(data + home + "/Downloads/small-old.txt", size: 1000, modified: Date(timeIntervalSince1970: 10 * 86_400))
        return Fixture.scan(fs, volume: Fixture.startup).0
    }

    @Test func findsEachCategoryAndSelectsNothing() {
        let found = SuggestionFinder.find(in: store(), home: home, now: now)
        #expect(found.map(\.category) == [.caches, .xcodeDerivedData, .simulators, .iosBackups, .oldDownloads])
        #expect(found.flatMap(\.items).allSatisfy { !$0.isSelected })
        #expect(found.allSatisfy { !$0.explanation.isEmpty })
        #expect(found[0].items.map(\.path) == [home + "/Library/Caches/com.big.App"])
        #expect(found.last!.items.map(\.path) == [home + "/Downloads/old.iso", home + "/Downloads/nested/old.zip"])
    }

    @Test func suggestedItemsAreNeverTheProtectedParents() {
        let fs = Fixture.fileSystem()
        fs.addFile(data + home + "/Library/Caches/com.big.App/blob", size: 5_000_000)
        let s = Fixture.scan(fs, volume: Fixture.startup).0
        let policy = Fixture.policy(fs)
        for item in SuggestionFinder.find(in: s, home: home, now: now).flatMap(\.items) {
            #expect(policy.check(item.path) == .allowed)
        }
    }
}

@Suite struct PreferenceTests {
    @Test func dockIconIsShownByDefaultAndRemembered() {
        let memory = MemoryPreferences()
        let prefs = Preferences(store: memory)
        #expect(prefs.showDockIcon)
        #expect(Presence.activationPolicy(showDockIcon: prefs.showDockIcon) == .regular)
        prefs.showDockIcon = false
        #expect(!Preferences(store: memory).showDockIcon)
        #expect(Presence.activationPolicy(showDockIcon: false) == .accessory)
    }

    @Test func allowlistIsRemembered() {
        let memory = MemoryPreferences()
        Preferences(store: memory).allowlist = ["/Library/Caches"]
        #expect(Preferences(store: memory).allowlist == ["/Library/Caches"])
    }
}
