import Foundation
import Testing
@testable import UninstallCore

@Suite struct ScannerTests {
    let home = Fixture.home
    var lib: String { home + "/Library" }

    func scan(_ app: AppIdentity, _ fs: FakeFileSystem, others: [AppIdentity] = [], receipts: [PackageReceipt] = [],
              launchServices: [String: [String]] = [:]) -> [String: Finding] {
        let result = Scanner(fileSystem: fs, locations: Fixture.locations, otherApps: others, receipts: receipts,
                             launchServices: launchServices).scan(app)
        return Dictionary(result.findings.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    @Test func findsBundleIDDataHelpersGroupsAndTheAppItself() {
        let fs = Fixture.fileSystem()
        let app = Fixture.app("com.acme.Foo", names: ["Foo"], team: "ABCDE12345", groups: ["ABCDE12345.com.acme.shared"],
                              nested: ["com.acme.Foo.LoginHelper"])
        fs.addDir(app.path)
        fs.addFile(lib + "/Preferences/com.acme.Foo.plist")
        fs.addFile(lib + "/Preferences/ByHost/com.acme.Foo.0A1B2C3D-0000-1111-2222-333344445555.plist")
        fs.addDir(lib + "/Caches/com.acme.Foo.ShipIt")
        fs.addDir(lib + "/Containers/com.acme.Foo.LoginHelper")
        fs.addDir(lib + "/Group Containers/ABCDE12345.com.acme.shared")
        fs.addDir(lib + "/Saved Application State/com.acme.Foo.savedState")
        let found = scan(app, fs)

        #expect(found[app.path]?.reason == .appBundle)
        #expect(found[lib + "/Preferences/com.acme.Foo.plist"]?.confidence == .high)
        #expect(found[lib + "/Preferences/ByHost/com.acme.Foo.0A1B2C3D-0000-1111-2222-333344445555.plist"]?.confidence == .high)
        #expect(found[lib + "/Caches/com.acme.Foo.ShipIt"]?.confidence == .high)
        #expect(found[lib + "/Containers/com.acme.Foo.LoginHelper"]?.reason == .nestedBundleID("com.acme.Foo.LoginHelper"))
        #expect(found[lib + "/Group Containers/ABCDE12345.com.acme.shared"]?.reason == .appGroup("ABCDE12345.com.acme.shared"))
        #expect(found[lib + "/Saved Application State/com.acme.Foo.savedState"] != nil)
        #expect(found.values.allSatisfy { $0.preselectedForUninstall })
    }

    @Test func stringPrefixIsNotAMatch() {
        let fs = Fixture.fileSystem()
        let app = Fixture.app("com.acme.Bar", names: ["Bar"])
        fs.addFile(lib + "/Preferences/com.acme.Barcode.plist")
        fs.addDir(lib + "/Application Support/Barcode")
        let found = scan(app, fs)
        // Not a component of com.acme.Bar; at most a same-vendor guess, never ticked.
        #expect(found[lib + "/Preferences/com.acme.Barcode.plist"]?.reason == .sameVendor("com.acme"))
        #expect(found[lib + "/Preferences/com.acme.Barcode.plist"]?.preselectedForUninstall == false)
        #expect(found[lib + "/Application Support/Barcode"] == nil)
    }

    @Test func moreSpecificInstalledAppKeepsItsData() {
        let fs = Fixture.fileSystem()
        let bar = Fixture.app("com.acme.Bar", names: ["Bar"])
        let pro = Fixture.app("com.acme.Bar.Pro", names: ["Bar Pro"])
        fs.addFile(lib + "/Preferences/com.acme.Bar.Pro.plist")
        fs.addFile(lib + "/Preferences/com.acme.Bar.plist")
        let found = scan(bar, fs, others: [pro])
        #expect(found[lib + "/Preferences/com.acme.Bar.Pro.plist"] == nil)
        #expect(found[lib + "/Preferences/com.acme.Bar.plist"] != nil)
    }

    @Test func launchServicesKnownOtherAppKeepsItsData() {
        // Chrome must not take Chrome for Testing's settings.
        let fs = Fixture.fileSystem()
        let chrome = Fixture.app("com.google.Chrome", names: ["Google Chrome"])
        fs.addFile(lib + "/Preferences/com.google.chrome.for.testing.plist")
        let found = scan(chrome, fs, launchServices: ["com.google.chrome.for.testing": ["/opt/cft/Google Chrome for Testing.app"]])
        #expect(found[lib + "/Preferences/com.google.chrome.for.testing.plist"] == nil)
    }

    @Test func extraComponentsLowerConfidence() {
        let fs = Fixture.fileSystem()
        let app = Fixture.app("com.acme.Foo", names: ["Foo"])
        fs.addFile(lib + "/Preferences/com.acme.Foo.beta.channel.plist")
        #expect(scan(app, fs)[lib + "/Preferences/com.acme.Foo.beta.channel.plist"]?.confidence == .medium)
    }

    @Test func genericNameIsLowAndNotTicked() {
        let fs = Fixture.fileSystem()
        let code = Fixture.app("com.microsoft.VSCode", names: ["Code", "Visual Studio Code"], exec: "Code")
        fs.addDir(lib + "/Application Support/Code")
        let finding = scan(code, fs)[lib + "/Application Support/Code"]
        #expect(finding?.confidence == .low)
        #expect(finding?.preselectedForUninstall == false)
    }

    @Test func distinctiveNameIsMediumAndTicked() {
        let fs = Fixture.fileSystem()
        let slack = Fixture.app("com.tinyspeck.slackmacgap", names: ["Slack"])
        fs.addDir(lib + "/Application Support/Slack")
        let finding = scan(slack, fs)[lib + "/Application Support/Slack"]
        #expect(finding?.confidence == .medium)
        #expect(finding?.preselectedForUninstall == true)
    }

    @Test func nameSharedWithAnotherInstalledAppIsLow() {
        let fs = Fixture.fileSystem()
        let a = Fixture.app("com.one.Notes2", names: ["Jotter"])
        let b = Fixture.app("com.two.jot", names: ["Jotter"], path: "/Applications/Jotter 2.app")
        fs.addDir(lib + "/Application Support/Jotter")
        let finding = scan(a, fs, others: [b])[lib + "/Application Support/Jotter"]
        #expect(finding?.confidence == .low)
        #expect(finding?.sharedWith == ["Jotter"])
        #expect(finding?.preselectedForUninstall == false)
    }

    @Test func vendorFolderChild() {
        let fs = Fixture.fileSystem()
        let chrome = Fixture.app("com.google.Chrome", names: ["Google Chrome"])
        fs.addDir(lib + "/Application Support/Google/Chrome")
        fs.addDir(lib + "/Application Support/Google/Earth")
        let found = scan(chrome, fs)
        #expect(found[lib + "/Application Support/Google/Chrome"]?.confidence == .medium)
        #expect(found[lib + "/Application Support/Google/Earth"] == nil)
        #expect(found[lib + "/Application Support/Google"] == nil)
    }

    @Test func sameVendorOnlyWhenNoOtherAppOfThatVendor() {
        let fs = Fixture.fileSystem()
        let docker = Fixture.app("com.docker.docker", names: ["Docker"])
        fs.addFile("/Library/LaunchDaemons/com.docker.vmnetd.plist")
        let alone = scan(docker, fs)[ "/Library/LaunchDaemons/com.docker.vmnetd.plist"]
        #expect(alone?.confidence == .medium)
        #expect(alone?.domain == .system)
        #expect(alone?.preselectedForUninstall == false) // administrator items are never ticked

        let other = Fixture.app("com.docker.extension", names: ["Docker Extension"])
        #expect(scan(docker, fs, others: [other])["/Library/LaunchDaemons/com.docker.vmnetd.plist"] == nil)
    }

    @Test func sharedNamespaceIsNotAVendor() {
        let fs = Fixture.fileSystem()
        let app = Fixture.app("com.github.SomeApp", names: ["SomeApp"])
        fs.addFile(lib + "/Preferences/com.github.OtherApp.plist")
        #expect(scan(app, fs)[lib + "/Preferences/com.github.OtherApp.plist"] == nil)
    }

    @Test func sharedAppGroupIsNotTicked() {
        let fs = Fixture.fileSystem()
        let word = Fixture.app("com.microsoft.Word", names: ["Word"], team: "UBF8T346G9", groups: ["UBF8T346G9.Office"])
        let excel = Fixture.app("com.microsoft.Excel", names: ["Excel"], team: "UBF8T346G9", groups: ["UBF8T346G9.Office"])
        fs.addDir(lib + "/Group Containers/UBF8T346G9.Office")
        let finding = scan(word, fs, others: [excel])[lib + "/Group Containers/UBF8T346G9.Office"]
        #expect(finding?.sharedWith == ["Excel"])
        #expect(finding?.preselectedForUninstall == false)
    }

    @Test func otherTeamWithSameIdentifierIsNotMatched() {
        let fs = Fixture.fileSystem()
        let app = Fixture.app("com.acme.Foo", names: ["Foo"], team: "AAAAAAAAAA")
        fs.addDir(lib + "/Group Containers/BBBBBBBBBB.com.acme.Foo")
        #expect(scan(app, fs)[lib + "/Group Containers/BBBBBBBBBB.com.acme.Foo"] == nil)
    }

    @Test func launchAgentRunningProgramInsideTheApp() throws {
        let fs = Fixture.fileSystem()
        let app = Fixture.app("com.acme.Foo", names: ["Foo"])
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Label": "net.other.updater",
                                                                         "ProgramArguments": [app.path + "/Contents/MacOS/updater"]],
                                                       format: .xml, options: 0)
        fs.addFile(lib + "/LaunchAgents/net.other.updater.plist", data: plist)
        #expect(scan(app, fs)[lib + "/LaunchAgents/net.other.updater.plist"]?.reason
            == .launchItemProgram(app.path + "/Contents/MacOS/updater"))
    }

    @Test func receiptByIdentifierOrFile() {
        let fs = Fixture.fileSystem()
        let app = Fixture.app("com.acme.Foo", names: ["Foo"])
        let found = scan(app, fs, receipts: [PackageReceipt(id: "com.acme.Foo.pkg", files: []),
                                             PackageReceipt(id: "com.vendor.installer", files: ["Applications/Foo.app"]),
                                             PackageReceipt(id: "com.vendor.other", files: ["Applications/Other.app"])])
        #expect(found["pkgutil:com.acme.Foo.pkg"] != nil)
        #expect(found["pkgutil:com.vendor.installer"] != nil)
        #expect(found["pkgutil:com.vendor.other"] == nil)
        #expect(found["pkgutil:com.acme.Foo.pkg"]?.preselectedForUninstall == false)
    }

    @Test func itemsOwnedBySomeoneElseNeedAnAdministratorAndAreNotTicked() {
        // App Store apps are owned by root: moving them needs a password, even in /Applications.
        let fs = Fixture.fileSystem()
        let app = Fixture.app("com.microsoft.Powerpoint", names: ["Microsoft PowerPoint"])
        fs.addDir(app.path, owner: 0)
        fs.addDir(lib + "/Containers/com.microsoft.Powerpoint", owner: 501)
        fs.addDir(lib + "/Caches/com.microsoft.Powerpoint", owner: 0)
        let found = Dictionary(Scanner(fileSystem: fs, locations: Fixture.locations, otherApps: [], userID: 501)
            .scan(app).findings.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(found[app.path]?.domain == .system)
        #expect(found[app.path]?.preselectedForUninstall == false)
        #expect(found[lib + "/Caches/com.microsoft.Powerpoint"]?.domain == .system)
        #expect(found[lib + "/Containers/com.microsoft.Powerpoint"]?.domain == .user)
        #expect(found[lib + "/Containers/com.microsoft.Powerpoint"]?.preselectedForUninstall == true)
    }

    @Test func ownAppStaysInTheUserDomain() {
        let fs = Fixture.fileSystem()
        let app = Fixture.app("com.acme.Foo", names: ["Foo"])
        fs.addDir(app.path, owner: 501)
        let finding = Scanner(fileSystem: fs, locations: [], otherApps: [], userID: 501).scan(app).findings.first
        #expect(finding?.domain == .user)
        #expect(finding?.preselectedForUninstall == true)
    }

    @Test func unreadableLocationIsReportedNotSkippedSilently() {
        let fs = Fixture.fileSystem()
        fs.denied.insert(lib + "/Containers")
        let result = Scanner(fileSystem: fs, locations: Fixture.locations, otherApps: []).scan(Fixture.app("com.a.b", names: ["B"]))
        #expect(result.unreadable.map(\.path) == [lib + "/Containers"])
    }
}
