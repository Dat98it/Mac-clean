import Testing
@testable import UninstallCore

@Suite struct BundleIDsTests {
    @Test func componentNeedsDotBoundary() {
        #expect(BundleIDs.isComponent("com.foo.Bar.helper", of: "com.foo.bar"))
        #expect(!BundleIDs.isComponent("com.foo.Barcode", of: "com.foo.Bar"))
    }
}

@Suite struct BundleIDsMoreTests {
    @Test func shapes() {
        #expect(BundleIDs.looksLikeBundleID("com.foo.bar"))
        #expect(!BundleIDs.looksLikeBundleID("com.foo"))
        #expect(!BundleIDs.looksLikeBundleID("Google Chrome"))
        #expect(!BundleIDs.looksLikeBundleID("default.store-wal"))
        #expect(BundleIDs.splitTeamPrefix("UBF8T346G9.Office")?.team == "UBF8T346G9")
        #expect(BundleIDs.splitTeamPrefix("group.com.foo") == nil)
        #expect(BundleIDs.dropHardwareUUID("com.foo.bar.0A1B2C3D-0000-1111-2222-333344445555") == "com.foo.bar")
        #expect(BundleIDs.stripFileSuffix("com.foo.bar.savedState") == "com.foo.bar")
    }

    @Test func apple() {
        #expect(BundleIDs.isApple("com.apple.Safari"))
        #expect(BundleIDs.isApple("group.com.apple.notes"))
        #expect(!BundleIDs.isApple("com.applesauce.app"))
        #expect(OrphanFinder.isAppleComponent("groups.com.apple.podcasts"))
        #expect(OrphanFinder.isAppleComponent("is.workflow.shortcuts"))
    }
}
