import AppKit
import MacCleanCore
import MacCleanSystem
import UninstallSystem

// Before anything touches the disk: reading a dataless (iCloud) file's attributes must never download it.
Downloads.disableMaterialization()

// `--sandbox <folder>`: work on a throwaway folder tree instead of this Mac. See MacCleanEnvironment.
let args = CommandLine.arguments
let bundlePath = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.path : nil
let env: MacCleanEnvironment
let uninstallEnv: CleanerEnvironment
let store: PreferenceStoring
if let i = args.firstIndex(of: "--sandbox"), i + 1 < args.count {
    env = .sandbox(root: args[i + 1], selfBundlePath: bundlePath)
    // The uninstaller works on the same tree: home/, Library/, Applications/ (and Volumes/ for the disk explorer).
    uninstallEnv = .sandbox(root: args[i + 1], selfBundlePath: bundlePath, selfBundleID: Bundle.main.bundleIdentifier)
    // Settings of a sandbox run stay in the sandbox folder, not in ~/Library/Preferences.
    store = FilePreferences(file: env.sandboxRoot! + "/settings.plist")
    // No saved window state either (~/Library/Saved Application State).
    UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
} else {
    env = .live(selfBundlePath: bundlePath)
    uninstallEnv = .live(selfBundlePath: bundlePath, selfBundleID: Bundle.main.bundleIdentifier)
    store = DefaultsStore()
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate(env: env, uninstallEnv: uninstallEnv, prefs: Preferences(store: store)) }
app.delegate = delegate
app.run()
