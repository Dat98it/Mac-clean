import Foundation
import Testing
@testable import MacCleanCore

@Suite struct SafetyPolicyTests {
    let home = Fixture.home

    func verdict(_ path: String, _ fs: FakeFileSystem, allowlist: [String] = []) -> SafetyPolicy.Verdict {
        Fixture.policy(fs, allowlist: allowlist).check(path)
    }

    func denied(_ path: String, _ fs: FakeFileSystem, allowlist: [String] = []) -> Bool {
        !verdict(path, fs, allowlist: allowlist).isAllowed
    }

    @Test func ordinaryItemsInZonesAreAllowed() {
        let fs = Fixture.fileSystem()
        fs.addFile(home + "/Downloads/big.dmg")
        fs.addDir(home + "/Library/Caches/com.example.App")
        fs.addDir(home + "/Projects/old/build")
        fs.addFile("/Volumes/Ext/Movies/film.mov")
        #expect(verdict(home + "/Downloads/big.dmg", fs) == .allowed)
        #expect(verdict(home + "/Library/Caches/com.example.App", fs) == .allowed)
        #expect(verdict(home + "/Projects/old/build", fs) == .allowed)
        #expect(verdict("/Volumes/Ext/Movies/film.mov", fs) == .allowed)
        #expect(verdict("/Volumes/Ext/Movies", fs) == .allowed)
    }

    @Test(arguments: [
        "/", "/System", "/Users", "/Applications", "/Library", "/usr/bin", "/private/var/db/receipts", "/Volumes",
        "/Users/tester", "/Users/tester/Documents", "/Users/tester/Desktop", "/Users/tester/Downloads", "/Users/tester/Pictures",
        "/Users/tester/Library", "/Users/tester/Library/Caches", "/Users/tester/Library/Application Support",
        "/Users/tester/Library/Preferences", "/Users/tester/Library/Containers",
        "/Users/tester/Library/Keychains", "/Users/tester/Library/Keychains/login.keychain-db",
        "/Users/tester/Library/Mail", "/Users/tester/Library/Mail/V10/x.mbox",
        "/Users/tester/Library/Messages/chat.db", "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/a.txt",
        "/Users/tester/Library/CloudStorage/Dropbox/a.txt", "/Users/tester/Library/Cookies/x",
        "/Users/tester/.Trash", "/Users/tester/.Trash/old", "/Users/tester/Pictures/Photos Library.photoslibrary",
        "/Users/tester/Pictures/Photos Library.photoslibrary/originals/a.heic",
        "/Volumes/Ext", "/Volumes/Ext/.Trashes", "/Volumes/Ext/.Trashes/501/x", "/Volumes/Ext/.Spotlight-V100",
        "/Volumes/Ext/.fseventsd/0001", "/System/Volumes/Data", "/System/Volumes/Data/Users/tester/x",
    ])
    func protectedPlacesAreDenied(_ path: String) {
        let fs = Fixture.fileSystem()
        if !fs.has(path) { path.hasSuffix(".heic") || path.hasSuffix(".db") || path.hasSuffix("/x") ? fs.addFile(path) : fs.addDir(path) }
        #expect(denied(path, fs))
    }

    @Test(arguments: [
        "Users/tester/Downloads/x", "/Users/tester/Downloads/../Documents", "/Users/tester/Downloads/./x",
        "/Users/tester/Downloads//x", "/Users/tester/Downloads/x/", "/Users/tester/Downloads/a\nb",
    ])
    func malformedPathsAreDenied(_ path: String) {
        let fs = Fixture.fileSystem()
        fs.addDir(home + "/Downloads/x")
        #expect(denied(path, fs))
    }

    @Test func shapeLayerOnItsOwn() {
        #expect(SafetyPolicy.shapeProblem("Users/tester/x") == "not an absolute path")
        #expect(SafetyPolicy.shapeProblem("/") == "not an absolute path")
        #expect(SafetyPolicy.shapeProblem("/Users/tester/x/") == "not an absolute path")
        #expect(SafetyPolicy.shapeProblem("/Users/tester/a\nb") == "control characters in path")
        #expect(SafetyPolicy.shapeProblem("/Users/tester/a\rb") == "control characters in path")
        #expect(SafetyPolicy.shapeProblem("/Users/tester/a\u{0}b") == "control characters in path")
        #expect(SafetyPolicy.shapeProblem("/Users/tester/../x") == "path is not normalized")
        #expect(SafetyPolicy.shapeProblem("/Users/tester/x") == nil)
    }

    /// With a file system that says yes to everything, only the shape check stops these.
    @Test func checkUsesTheShapeLayer() {
        let policy = SafetyPolicy(fileSystem: AnythingGoes(), home: home, volumes: Fixture.volumes)
        #expect(policy.check(home + "/Downloads/a\nb") == .denied("control characters in path"))
        #expect(policy.check(home + "/Downloads/a/") == .denied("not an absolute path"))
        #expect(policy.check(home + "/Downloads/a") == .allowed)
    }

    @Test func outsideTheZonesIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addDir("/Library/Caches/com.example")
        fs.addDir("/Applications/Foo.app")
        fs.addDir("/private/var/folders/x")
        fs.addDir("/opt/homebrew/x")
        #expect(verdict("/Library/Caches/com.example", fs) == .denied("outside the folders Mac Clean may clean"))
        #expect(denied("/Applications/Foo.app", fs))
        #expect(denied("/private/var/folders/x", fs))
        #expect(denied("/opt/homebrew/x", fs))
    }

    @Test func allowlistOpensAFolder() {
        let fs = Fixture.fileSystem()
        fs.addDir("/Library/Caches/com.example")
        #expect(verdict("/Library/Caches/com.example", fs, allowlist: ["/Library/Caches"]) == .allowed)
        // The allowlisted folder itself stays.
        #expect(denied("/Library/Caches", fs, allowlist: ["/Library/Caches"]))
    }

    @Test func readOnlyNtfsAndTimeMachineVolumesAreViewOnly() {
        let fs = Fixture.fileSystem()
        fs.addFile("/Volumes/RO/a.mov")
        fs.addFile("/Volumes/Win/a.mov")
        fs.addFile("/Volumes/TM/2026-10-01-120000.backup/x")
        #expect(verdict("/Volumes/RO/a.mov", fs) == .denied("volume is read-only"))
        #expect(verdict("/Volumes/Win/a.mov", fs) == .denied("volume is read-only"))
        #expect(verdict("/Volumes/TM/2026-10-01-120000.backup/x", fs) == .denied("Time Machine backup: view only"))
    }

    @Test func unknownVolumeIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addFile("/Volumes/Ext/a")
        var policy = Fixture.policy(fs)
        policy.volumes = [Fixture.startup]
        #expect(policy.check("/Volumes/Ext/a") == .denied("not on a known volume"))
    }

    @Test func symbolicLinkOnTheWayIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addDir("/System/Library/Fonts")
        fs.addSymlink(home + "/Downloads/fonts", to: "/System/Library")
        // The link itself may go (it is removed as a link), but nothing reached through it.
        #expect(verdict(home + "/Downloads/fonts", fs) == .allowed)
        #expect(denied(home + "/Downloads/fonts/Fonts", fs))
    }

    @Test func linkedParentInsideHomeIsDeniedToo() {
        let fs = Fixture.fileSystem()
        fs.addFile(home + "/Real/a.bin")
        fs.addSymlink(home + "/Alias", to: home + "/Real")
        #expect(verdict(home + "/Alias/a.bin", fs) == .denied("path goes through a symbolic link (/Users/tester/Real)"))
    }

    @Test func missingItemIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addDir(home + "/Downloads")
        #expect(verdict(home + "/Downloads/nothing", fs) == .denied("does not exist"))
    }

    @Test func thisAppIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addDir("/Applications/Mac Clean.app/Contents")
        var policy = Fixture.policy(fs, allowlist: ["/Applications"])
        #expect(policy.check("/Applications/Mac Clean.app") == .denied("Mac Clean itself"))
        #expect(policy.check("/Applications/Mac Clean.app/Contents") == .denied("Mac Clean itself"))
        policy.selfBundlePath = home + "/Apps/Mac Clean.app"
        fs.addDir(home + "/Apps/Mac Clean.app")
        #expect(policy.check(home + "/Apps") == .denied("Mac Clean itself"))
    }

    /// The "contains a protected folder" layer on its own: in the default setup every protected
    /// tree sits in a protected folder, so give it a tree that does not.
    @Test func containingAProtectedTreeIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addDir(home + "/Work/Keep/inner")
        var policy = Fixture.policy(fs)
        policy.extraProtectedTrees = [home + "/Work/Keep"]
        #expect(policy.check(home + "/Work") == .denied("contains protected folder /Users/tester/Work/Keep"))
        #expect(policy.check(home + "/Work/Keep/inner") == .denied("inside protected folder /Users/tester/Work/Keep"))
        #expect(policy.check(home + "/Work/Keep") == .denied("inside protected folder /Users/tester/Work/Keep"))
    }

    @Test func protectedPathsLayerOnItsOwn() {
        // Inside the home zone, not in any tree: only the exact-path list stops it.
        let fs = Fixture.fileSystem()
        fs.addDir(home + "/Library/Preferences")
        #expect(verdict(home + "/Library/Preferences", fs) == .denied("protected folder"))
    }

    @Test func trashInsideAnAllowedZoneIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addFile(home + "/Stuff/.Trash/x")
        fs.addFile("/Volumes/Ext/Projects/.Trashes/y")
        #expect(verdict(home + "/Stuff/.Trash/x", fs) == .denied("Trash folder"))
        #expect(verdict("/Volumes/Ext/Projects/.Trashes/y", fs) == .denied("Trash folder"))
    }

    @Test func photosLibraryAnywhereIsDenied() {
        let fs = Fixture.fileSystem()
        fs.addFile("/Volumes/Ext/Backup/Old.photoslibrary/database/Photos.sqlite")
        #expect(verdict("/Volumes/Ext/Backup/Old.photoslibrary", fs) == .denied("Photos library"))
        #expect(verdict("/Volumes/Ext/Backup/Old.photoslibrary/database/Photos.sqlite", fs) == .denied("Photos library"))
    }

    @Test func volumeBookkeepingFoldersAreDenied() {
        // .Spotlight-V100 is also caught by other rules; .DocumentRevisions-V100 only by this one.
        let fs = Fixture.fileSystem()
        fs.addFile("/Volumes/Ext/.DocumentRevisions-V100/x")
        #expect(verdict("/Volumes/Ext/.DocumentRevisions-V100/x", fs) == .denied("volume bookkeeping folder"))
    }

    @Test func allowlistValidation() {
        let fs = Fixture.fileSystem()
        fs.addDir("/Library/Caches")
        fs.addDir(home + "/Library/Mail/V10")
        fs.addDir(home + "/Work")
        fs.addSymlink(home + "/WorkLink", to: home + "/Work")
        let policy = Fixture.policy(fs)
        #expect(policy.canAllowlist("/Library/Caches") == .allowed)
        #expect(!policy.canAllowlist("/Library").isAllowed)
        #expect(!policy.canAllowlist("/").isAllowed)
        #expect(!policy.canAllowlist(home).isAllowed)
        #expect(!policy.canAllowlist("/Volumes/Ext").isAllowed)
        #expect(!policy.canAllowlist(home + "/Library/Mail/V10").isAllowed)
        #expect(!policy.canAllowlist("/System/Library").isAllowed)
        #expect(!policy.canAllowlist(home + "/WorkLink").isAllowed)
        #expect(!policy.canAllowlist("/private/var/db").isAllowed)
    }
}

/// Every path exists, as a file, and no link is ever on the way.
struct AnythingGoes: FileSystem {
    func info(_ path: String) throws -> FileInfo { FileInfo(type: .regular, inode: 1) }
    func canonicalPath(_ path: String) throws -> String { path }
}
