// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacClean",
    platforms: [.macOS(.v15)],
    targets: [
        // Disk explorer. Every decision: the tree, scanning rules, sizes, safety, deletion plans, suggestions.
        // Foundation only, and no direct file I/O: reading goes through `FileSystem` and
        // `DirectoryReading`, changes through `Trashing`, `PermanentRemoving`, `AdminActing`.
        .target(name: "MacCleanCore", path: "Sources/MacCleanCore"),
        // The real machine: getattrlistbulk, lstat, mounted volumes, the Trash, the password dialog.
        .target(name: "MacCleanSystem", dependencies: ["MacCleanCore"], path: "Sources/MacCleanSystem"),
        // App uninstaller and leftovers finder (adapted from App Clean). Same layering as the disk explorer,
        // with its own safety policy and deletion engine: the two never share a decision.
        .target(name: "UninstallCore", path: "Sources/UninstallCore"),
        .target(name: "UninstallSystem", dependencies: ["UninstallCore"], path: "Sources/UninstallSystem"),
        // The app: a thin layer that wires the Cores and Systems to AppKit and SwiftUI.
        .executableTarget(name: "MacClean",
                          dependencies: ["MacCleanCore", "MacCleanSystem", "UninstallCore", "UninstallSystem"],
                          path: "Sources/MacClean"),
        // Read-only command line tool for spikes and diagnosis. Has no code that removes anything.
        .executableTarget(name: "macclean-probe",
                          dependencies: ["MacCleanCore", "MacCleanSystem", "UninstallCore", "UninstallSystem"],
                          path: "Sources/macclean-probe"),
        .testTarget(name: "MacCleanCoreTests", dependencies: ["MacCleanCore"], path: "Tests/MacCleanCoreTests"),
        .testTarget(name: "UninstallCoreTests", dependencies: ["UninstallCore"], path: "Tests/UninstallCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
