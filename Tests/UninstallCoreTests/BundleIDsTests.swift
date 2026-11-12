import Testing
@testable import UninstallCore

@Suite struct BundleIDsTests {
    @Test func builtInApps() {
        // From the App Store, on the Data volume: the user's, even though Apple made it.
        #expect(!BundleIDs.isBuiltInApp(bundleID: "com.apple.TestFlight", path: "/Applications/TestFlight.app", hasAppStoreReceipt: true))
        #expect(!BundleIDs.isBuiltInApp(bundleID: "com.acme.Foo", path: "/Applications/Foo.app", hasAppStoreReceipt: false))
        // Apple apps without a receipt, and anything on the system volume, come with macOS.
        #expect(BundleIDs.isBuiltInApp(bundleID: "com.apple.Notes", path: "/Applications/Notes.app", hasAppStoreReceipt: false))
        #expect(BundleIDs.isBuiltInApp(bundleID: "com.apple.Notes", path: "/System/Applications/Notes.app", hasAppStoreReceipt: true))
        #expect(BundleIDs.isBuiltInApp(bundleID: "com.apple.Safari",
                                       path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
                                       hasAppStoreReceipt: true))
        #expect(BundleIDs.isBuiltInApp(bundleID: "com.acme.Foo", path: "/System/Applications/Foo.app", hasAppStoreReceipt: true))
    }

    @Test func appStoreAppleIDOnlyForAppleAppsFromTheAppStore() {
        #expect(AppIdentity(bundleID: "com.apple.TestFlight", path: "/Applications/TestFlight.app", names: ["TestFlight"],
                            hasAppStoreReceipt: true).appStoreAppleID == "com.apple.TestFlight")
        #expect(AppIdentity(bundleID: "com.apple.TestFlight", path: "/Applications/TestFlight.app", names: ["TestFlight"],
                            hasAppStoreReceipt: false).appStoreAppleID == nil)
        #expect(AppIdentity(bundleID: "com.acme.Foo", path: "/Applications/Foo.app", names: ["Foo"],
                            hasAppStoreReceipt: true).appStoreAppleID == nil)
    }

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
