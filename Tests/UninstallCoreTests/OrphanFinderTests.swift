import Foundation
import Testing
@testable import UninstallCore

@Suite struct OrphanFinderTests {
    let lib = Fixture.home + "/Library"

    func find(_ fs: FakeFileSystem, _ index: InstalledAppIndex = InstalledAppIndex(apps: []),
              ignored: IgnoreList = IgnoreList()) -> OrphanFinder.Result {
        OrphanFinder(fileSystem: fs, locations: Fixture.locations, index: index, now: Fixture.now, ignored: ignored).find()
    }

    func keys(_ r: OrphanFinder.Result) -> [String] { r.groups.map(\.key).sorted() }
    func reason(_ r: OrphanFinder.Result, _ key: String) -> OrphanExclusion? {
        (r.excluded + r.uncertain).first { $0.group.key == key }?.reason
    }

    /// Old data of an app that is gone.
    func leftover(_ fs: FakeFileSystem, _ id: String) {
        fs.addFile(lib + "/Preferences/\(id).plist", modified: Fixture.old)
        fs.addDir(lib + "/Caches/\(id)", modified: Fixture.old)
    }

    @Test func dataOfARemovedAppIsSuggestedAndGrouped() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.gone.App")
        fs.addDir(lib + "/Caches/com.gone.App.ShipIt", modified: Fixture.old)
        let r = find(fs)
        #expect(keys(r) == ["com.gone.app"])
        #expect(r.groups[0].entries.count == 3)
    }

    @Test func appleDataIsNeverSuggested() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.apple.Safari")
        fs.addDir(lib + "/Group Containers/group.com.apple.notes", modified: Fixture.old)
        fs.addDir(lib + "/Group Containers/243LU875E5.groups.com.apple.podcasts", modified: Fixture.old)
        fs.addDir(lib + "/Group Containers/group.is.workflow.shortcuts", modified: Fixture.old)
        fs.addDir(lib + "/Application Support/AddressBook", modified: Fixture.old)
        fs.addDir(lib + "/Application Support/contactsd", modified: Fixture.old)
        let r = find(fs)
        #expect(r.groups.isEmpty)
        #expect(r.unknownOwner.isEmpty)
    }

    @Test func installedAppAndItsHelpersAreNotOrphans() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.here.App")
        leftover(fs, "com.here.App.helper")
        leftover(fs, "com.here.Widget")
        let app = Fixture.app("com.here.App", names: ["Here"], nested: ["com.here.Widget"])
        let r = find(fs, InstalledAppIndex(apps: [app]))
        #expect(r.groups.isEmpty)
        #expect(reason(r, "com.here.app") == .installed)
    }

    @Test func parentIdentifierOfAnInstalledAppIsNotAnOrphan() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.here.suite")
        let r = find(fs, InstalledAppIndex(apps: [Fixture.app("com.here.suite.editor", names: ["Editor"])]))
        #expect(r.groups.isEmpty)
        #expect(reason(r, "com.here.suite") == .relatedToInstalled)
    }

    @Test func helperDataOfAnInstalledAppIsNotAnOrphan() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.here.App.ShipIt")
        let r = find(fs, InstalledAppIndex(apps: [Fixture.app("com.here.App", names: ["Here"])]))
        #expect(r.groups.isEmpty)
        #expect(r.uncertain.isEmpty)
        #expect(reason(r, "com.here.app.shipit") == .relatedToInstalled)
    }

    @Test func sameVendorInstalledGoesToUncertainNotTheMainList() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.microsoft.Excel")
        let ppt = Fixture.app("com.microsoft.Powerpoint", names: ["PowerPoint"])
        let r = find(fs, InstalledAppIndex(apps: [ppt]))
        #expect(r.groups.isEmpty)
        #expect(r.uncertain.map(\.group.key) == ["com.microsoft.excel"])
    }

    @Test func sameTeamGroupContainerGoesToUncertain() {
        let fs = Fixture.fileSystem()
        fs.addDir(lib + "/Group Containers/UBF8T346G9.com.contoso.teams", modified: Fixture.old)
        let ppt = Fixture.app("com.microsoft.Powerpoint", names: ["PowerPoint"], team: "UBF8T346G9")
        let r = find(fs, InstalledAppIndex(apps: [ppt]))
        #expect(r.groups.isEmpty)
        #expect(r.uncertain.count == 1)
    }

    @Test func appOnAnUnpluggedDiskIsNotAnOrphan() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.ext.Tool")
        let index = InstalledAppIndex(apps: [], launchServices: ["com.ext.Tool": ["/Volumes/External/Tool.app"]])
        let r = find(fs, index)
        #expect(r.groups.isEmpty)
        #expect(reason(r, "com.ext.tool") == .maybeOnUnpluggedDisk)
    }

    @Test func appLaunchServicesFindsElsewhereIsNotAnOrphan() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.odd.Place")
        fs.addDir("/opt/odd/Place.app")
        let r = find(fs, InstalledAppIndex(apps: [], launchServices: ["com.odd.place": ["/opt/odd/Place.app"]]))
        #expect(reason(r, "com.odd.place") == .launchServicesKnown)
    }

    @Test func runningProcessAndLivePackageAreNotOrphans() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.run.Agent")
        leftover(fs, "com.pkg.Driver")
        let r = find(fs, InstalledAppIndex(apps: [], livePackageIDs: ["com.pkg.Driver"], runningIDs: ["com.run.Agent"]))
        #expect(r.groups.isEmpty)
    }

    @Test func commandLineToolsAndLibrariesAreNotOrphans() {
        let fs = Fixture.fileSystem()
        fs.addFile(lib + "/LaunchAgents/homebrew.mxcl.mysql.plist", modified: Fixture.old)
        fs.addDir(lib + "/Caches/org.swift.swiftpm", modified: Fixture.old)
        fs.addDir(lib + "/Caches/com.onevcat.Kingfisher.ImageCache.default", modified: Fixture.old)
        fs.addFile(lib + "/Preferences/com.segment.storage.oai.plist", modified: Fixture.old)
        let r = find(fs, InstalledAppIndex(apps: [], commandLineTools: ["mysql", "swift"]))
        #expect(r.groups.isEmpty)
    }

    @Test func recentlyModifiedDataIsNotSuggested() {
        let fs = Fixture.fileSystem()
        fs.addDir(lib + "/Caches/com.busy.App", modified: Fixture.now.addingTimeInterval(-3600))
        let r = find(fs)
        #expect(r.groups.isEmpty)
        #expect(reason(r, "com.busy.app") == .recentlyModified)
    }

    @Test func recentChildMakesTheFolderRecent() {
        let fs = Fixture.fileSystem()
        fs.addDir(lib + "/Caches/com.busy.App", modified: Fixture.old)
        fs.addFile(lib + "/Caches/com.busy.App/db", modified: Fixture.now.addingTimeInterval(-60))
        #expect(find(fs).groups.isEmpty)
    }

    @Test func ignoredGroupIsNotSuggestedAgain() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.gone.App")
        var ignored = IgnoreList()
        ignored.add("com.gone.app")
        #expect(find(fs, ignored: ignored).groups.isEmpty)
    }

    @Test func vendorWithNothingInstalledIsOneGroup() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.coccoc.Coccoc")
        fs.addFile(lib + "/LaunchAgents/com.coccoc.keystone.agent.plist", modified: Fixture.old)
        let r = find(fs)
        #expect(r.groups.count == 1)
        #expect(r.groups[0].entries.count == 3)
    }

    @Test func nameOnlyFolderLinksToItsIdentifierGroupAsLow() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.electron.k6-studio")
        fs.addDir(lib + "/Application Support/k6 Studio", modified: Fixture.old)
        let r = find(fs)
        let entry = r.groups.first?.entries.first { $0.path.hasSuffix("k6 Studio") }
        #expect(entry?.confidence == .low)
        #expect(entry?.linkReason != nil)
    }

    @Test func nameOnlyFolderOfAnInstalledAppOrToolIsNotSuggested() {
        let fs = Fixture.fileSystem()
        for name in ["Slack", "Google", "Yarn", "ChatGPTHelper", "mysql-data", "SentryCrash"] {
            fs.addDir(lib + "/Application Support/\(name)", modified: Fixture.old)
        }
        fs.addDir(lib + "/Application Support/Arc", modified: Fixture.old)
        let index = InstalledAppIndex(apps: [Fixture.app("com.tinyspeck.slackmacgap", names: ["Slack"]),
                                             Fixture.app("com.google.Chrome", names: ["Google Chrome"]),
                                             Fixture.app("com.openai.chat", names: ["ChatGPT"])],
                                      commandLineTools: ["mysql"])
        let r = find(fs, index)
        #expect(r.unknownOwner.map(\.key) == ["Arc"])
        #expect(r.unknownOwner[0].entries[0].confidence == .low)
    }

    @Test func symlinksInLibraryAreIgnored() {
        let fs = Fixture.fileSystem()
        fs.addSymlink(lib + "/Caches/com.gone.Link", to: Fixture.home + "/Documents")
        #expect(find(fs).groups.isEmpty)
    }

    @Test func cancellationStopsTheScan() {
        let fs = Fixture.fileSystem()
        leftover(fs, "com.gone.App")
        let r = OrphanFinder(fileSystem: fs, locations: Fixture.locations, index: InstalledAppIndex(apps: []),
                             now: Fixture.now, isCancelled: { true }).find()
        #expect(r.cancelled)
        #expect(r.groups.isEmpty)
    }
}
