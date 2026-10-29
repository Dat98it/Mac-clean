import Foundation

/// A group of items that are often safe to remove, with why. Nothing is ever selected for the user:
/// a suggestion only points at items; the user ticks them.
public struct Suggestion: Sendable, Equatable, Identifiable {
    public enum Category: String, Sendable, CaseIterable {
        case caches, xcodeDerivedData, xcodeDeviceSupport, simulators, iosBackups, oldDownloads
    }

    public var id: Category { category }
    public var category: Category
    public var items: [Item]

    public struct Item: Sendable, Equatable {
        public var node: NodeID
        public var path: String
        public var bytes: UInt64
        /// Always false when found. Only the user changes it.
        public var isSelected: Bool = false
    }

    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    public var title: String {
        switch category {
        case .caches: "App caches"
        case .xcodeDerivedData: "Xcode DerivedData"
        case .xcodeDeviceSupport: "Xcode device support files"
        case .simulators: "iOS Simulator devices and caches"
        case .iosBackups: "iPhone and iPad backups"
        case .oldDownloads: "Large old files in Downloads"
        }
    }

    public var explanation: String {
        switch category {
        case .caches:
            "Apps keep temporary copies here to work faster. Removing them is usually safe: apps rebuild what they need, but may be slower the first time and may sign you out. Quit the app first."
        case .xcodeDerivedData:
            "Build products and indexes made by Xcode. Xcode rebuilds them; the next build of each project takes longer."
        case .xcodeDeviceSupport:
            "Debug symbols copied from each iOS version you connected. Xcode copies them again when a device with that version is connected."
        case .simulators:
            "Simulated devices and their apps and data. Removing a device folder loses everything installed in it. Quit Simulator and Xcode first; deleting devices from Xcode (Devices and Simulators) is cleaner."
        case .iosBackups:
            "Backups of your iPhone or iPad made by Finder. A removed backup cannot be restored. Keep at least one recent backup of each device you care about."
        case .oldDownloads:
            "Files of 100 MB or more in Downloads that have not changed for 90 days. Check each one: it may be the only copy."
        }
    }
}

public enum SuggestionFinder {
    public static let largeDownload: UInt64 = 100_000_000
    public static let oldDownloadDays = 90

    /// Looks only at what the scan already found on the startup disk. Never selects anything.
    public static func find(in store: NodeStore, home: String, now: Date, minimumBytes: UInt64 = 1_000_000) -> [Suggestion] {
        func childrenOf(_ path: String, limit: Int = 100) -> [Suggestion.Item] {
            guard let folder = store.find(path) else { return [] }
            return Browse.sort(store.children(folder), in: store, order: .default)
                .filter { store.size($0) >= minimumBytes }
                .prefix(limit)
                .map { Suggestion.Item(node: $0, path: store.path($0), bytes: store.size($0)) }
        }
        let developer = home + "/Library/Developer"
        var result: [Suggestion] = [
            Suggestion(category: .caches, items: childrenOf(home + "/Library/Caches")),
            Suggestion(category: .xcodeDerivedData, items: childrenOf(developer + "/Xcode/DerivedData")),
            Suggestion(category: .xcodeDeviceSupport, items: childrenOf(developer + "/Xcode/iOS DeviceSupport")
                + childrenOf(developer + "/Xcode/watchOS DeviceSupport")),
            Suggestion(category: .simulators, items: childrenOf(developer + "/CoreSimulator/Devices")
                + childrenOf(developer + "/CoreSimulator/Caches")),
            Suggestion(category: .iosBackups, items: childrenOf(home + "/Library/Application Support/MobileSync/Backup")),
        ]
        if let downloads = store.find(home + "/Downloads") {
            let cutoff = UInt32(max(0, now.timeIntervalSince1970 - Double(oldDownloadDays) * 86_400))
            var stack = [downloads]
            var found: [NodeID] = []
            while let node = stack.popLast() {
                for child in store.children(node) {
                    switch store.kind(child) {
                    case .directory where !store.flags(child).contains(.package):
                        stack.append(child)
                    case .file, .directory:
                        let modified = store.modifiedSeconds(child)
                        if store.size(child) >= largeDownload && modified != 0 && modified <= cutoff { found.append(child) }
                    default:
                        break
                    }
                }
            }
            let items = Browse.sort(found, in: store, order: .default).prefix(100).map {
                Suggestion.Item(node: $0, path: store.path($0), bytes: store.size($0))
            }
            result.append(Suggestion(category: .oldDownloads, items: Array(items)))
        }
        return result.filter { !$0.items.isEmpty }
    }
}
