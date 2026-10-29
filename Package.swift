// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacClean",
    platforms: [.macOS(.v14)],
    targets: [
        // Every decision: the tree, scanning rules, sizes, safety, deletion plans, suggestions.
        // Foundation only, and no direct file I/O: reading goes through `FileSystem` and
        // `DirectoryReading`, changes through `Trashing`, `PermanentRemoving`, `AdminActing`.
        .target(name: "MacCleanCore", path: "Sources/MacCleanCore"),
        // The real machine: getattrlistbulk, lstat, mounted volumes, the Trash, the password dialog.
        .target(name: "MacCleanSystem", dependencies: ["MacCleanCore"], path: "Sources/MacCleanSystem"),
        // The app: a thin layer that wires Core and System to AppKit.
        .executableTarget(name: "MacClean", dependencies: ["MacCleanCore", "MacCleanSystem"], path: "Sources/MacClean"),
        .testTarget(name: "MacCleanCoreTests", dependencies: ["MacCleanCore"], path: "Tests/MacCleanCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
