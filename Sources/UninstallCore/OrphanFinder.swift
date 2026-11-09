import Foundation

/// Everything known about apps that are still on this Mac, from every source the system layer found.
public struct InstalledAppIndex: Sendable {
    public var apps: [AppIdentity]
    /// Identifiers LaunchServices knows, with the paths it last saw them at. A path that no longer
    /// exists usually means the app lives on a disk that is not plugged in.
    public var launchServices: [String: [String]]
    /// Names of every app LaunchServices knows (system apps, agents, helpers included).
    public var launchServicesNames: Set<String>
    /// Installer packages whose files are still on disk (command line tools, drivers...).
    public var livePackageIDs: [String]
    public var runningIDs: [String]
    /// Names of installed command line tools: executables on the usual PATH folders and Homebrew
    /// formulae. Lower case.
    public var commandLineTools: Set<String>

    public init(apps: [AppIdentity], launchServices: [String: [String]] = [:], launchServicesNames: Set<String> = [],
                livePackageIDs: [String] = [], runningIDs: [String] = [], commandLineTools: Set<String> = []) {
        self.apps = apps
        self.launchServices = Dictionary(launchServices.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: +)
        self.launchServicesNames = Set(launchServicesNames.map { $0.lowercased() })
        self.livePackageIDs = livePackageIDs
        self.runningIDs = runningIDs
        self.commandLineTools = Set(commandLineTools.map { $0.lowercased() })
    }
}

/// Why an identifier found in ~/Library is *not* offered as left-over data.
public enum OrphanExclusion: String, Sendable, CaseIterable {
    case apple = "Apple / system"
    case installed = "app installed"
    case relatedToInstalled = "helper, extension or parent of an installed app"
    case launchServicesKnown = "LaunchServices knows the app at an existing path"
    case maybeOnUnpluggedDisk = "app registered on a disk that is not connected"
    case packageInstalled = "installer package still on disk"
    case running = "running"
    case commandLineTool = "matches an installed command line tool"
    case library = "written by a library used inside many apps"
    case sameVendorInstalled = "same developer still has an installed app"
    case recentlyModified = "modified recently"
    case ignoredByUser = "ignored by the user"
    case knownName = "name of an installed app, tool or system component"
}

public struct OrphanEntry: Sendable, Hashable {
    public var path: String
    public var kind: DataKind
    /// The identifier the entry is named after, or its folder name for name-only entries.
    public var identifier: String
    public var modified: Date
    public var confidence: Confidence
    /// Why a name-only folder was put in this group (`k6 Studio` ↔ `com.electron.k6-studio`).
    public var linkReason: String?
}

public struct OrphanGroup: Sendable, Equatable {
    /// The shortest identifier in the group (or the vendor), used as the "old app" name and as the
    /// key for "don't suggest again".
    public var key: String
    public var entries: [OrphanEntry]
    public var lastModified: Date { entries.map(\.modified).max() ?? .distantPast }
    public var mayHoldUserData: Bool { entries.contains { $0.kind.mayHoldUserData } }
}

/// Clean-up mode: finds data in ~/Library left by apps that are no longer installed.
///
/// Errs on the side of *not* suggesting: anything with a reason to think an app may still use it is
/// excluded, and every exclusion is recorded so a scan can be audited. Nothing it returns is ticked.
public struct OrphanFinder: Sendable {
    public var fileSystem: FileSystem
    public var locations: [Location]
    public var index: InstalledAppIndex
    public var now: Date
    public var recentInterval: TimeInterval
    public var ignored: IgnoreList
    public var isCancelled: @Sendable () -> Bool

    public init(fileSystem: FileSystem, locations: [Location], index: InstalledAppIndex, now: Date = Date(),
                recentInterval: TimeInterval = 14 * 24 * 3600, ignored: IgnoreList = IgnoreList(),
                isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.fileSystem = fileSystem
        self.locations = locations.filter { $0.domain == .user }
        self.index = index
        self.now = now
        self.recentInterval = recentInterval
        self.ignored = ignored
        self.isCancelled = isCancelled
    }

    public struct Excluded: Sendable {
        public var group: OrphanGroup
        public var reason: OrphanExclusion
        public var detail: String

        public init(group: OrphanGroup, reason: OrphanExclusion, detail: String) {
            self.group = group
            self.reason = reason
            self.detail = detail
        }
    }

    public struct Result: Sendable {
        /// Data of apps that are gone: the main list.
        public var groups: [OrphanGroup] = []
        /// Same developer still has an app installed: maybe shared, shown only on request.
        public var uncertain: [Excluded] = []
        /// Folders named after no known identifier and no installed app or tool: shown only on request.
        public var unknownOwner: [OrphanGroup] = []
        public var excluded: [Excluded] = []
        public var unreadable: [(path: String, error: FileSystemError)] = []
        public var cancelled = false
    }

    /// Folders searched for name-only entries (identifier-named entries are looked for everywhere).
    static let nameOnlyFolders = ["/Library/Application Support", "/Library/Caches", "/Library/Logs"]

    public func find() -> Result {
        var result = Result()
        var idEntries: [OrphanEntry] = []
        var nameEntries: [OrphanEntry] = []

        for location in locations {
            if isCancelled() { result.cancelled = true; return result }
            let names: [String]
            do {
                names = try fileSystem.contents(ofDirectory: location.path)
            } catch let error as FileSystemError {
                if case .notFound = error { continue }
                result.unreadable.append((location.path, error))
                continue
            } catch {
                continue
            }
            let nameOnly = Self.nameOnlyFolders.contains { location.path.hasSuffix($0) }
            for name in names where !name.hasPrefix(".") {
                let path = Paths.join(location.path, name)
                guard let info = try? fileSystem.info(path), info.type != .symlink else { continue }
                if let id = Self.identifier(fromEntry: name) {
                    idEntries.append(OrphanEntry(path: path, kind: location.kind, identifier: id,
                                                 modified: latestModification(path, info: info), confidence: .medium))
                } else if nameOnly, info.type == .directory {
                    nameEntries.append(OrphanEntry(path: path, kind: location.kind, identifier: name,
                                                   modified: latestModification(path, info: info), confidence: .low))
                }
            }
        }

        let installedVendors = Set(index.apps.compactMap(\.vendorPrefix))
        for group in Self.mergeByVendor(Self.group(idEntries), installedVendors: installedVendors) {
            if isCancelled() { result.cancelled = true; return result }
            if let (reason, detail) = exclusion(for: group) {
                let excluded = Excluded(group: group, reason: reason, detail: detail)
                if reason == .sameVendorInstalled { result.uncertain.append(excluded) } else { result.excluded.append(excluded) }
            } else {
                result.groups.append(group)
            }
        }

        // Name-only folders: attached (low) to the identifier group they clearly name, otherwise
        // listed as "unknown owner", unless they name anything still on this Mac.
        for entry in nameEntries {
            let single = OrphanGroup(key: entry.identifier, entries: [entry])
            if let (reason, detail) = nameExclusion(entry) {
                result.excluded.append(Excluded(group: single, reason: reason, detail: detail))
                continue
            }
            let token = Self.squash(entry.identifier)
            if let index = result.groups.firstIndex(where: { group in
                group.entries.contains { Self.lastIDComponentSquashed($0.identifier) == token }
            }) {
                var linked = entry
                linked.linkReason = "\(entry.identifier) ↔ \(result.groups[index].key)"
                result.groups[index].entries.append(linked)
            } else if now.timeIntervalSince(entry.modified) < recentInterval {
                result.excluded.append(Excluded(group: single, reason: .recentlyModified, detail: ""))
            } else {
                result.unknownOwner.append(single)
            }
        }
        return result
    }

    /// The identifier an entry is named after, or nil when the name is not identifier-shaped.
    /// `UBF8T346G9.com.foo.bar` → `com.foo.bar`, `group.com.foo` → `com.foo`,
    /// ByHost `com.foo.bar.<hardware UUID>.plist` → `com.foo.bar`.
    public static func identifier(fromEntry name: String) -> String? {
        var id = BundleIDs.stripFileSuffix(name)
        if let split = BundleIDs.splitTeamPrefix(id) { id = split.rest }
        id = BundleIDs.dropHardwareUUID(BundleIDs.stripGroupPrefix(id))
        return BundleIDs.looksLikeBundleID(id) ? id.lowercased() : nil
    }

    /// Groups entries under the shortest identifier that the others extend.
    static func group(_ entries: [OrphanEntry]) -> [OrphanGroup] {
        let ids = Set(entries.map(\.identifier)).sorted { $0.count < $1.count }
        var root: [String: String] = [:]
        for id in ids {
            root[id] = ids.first { $0.count < id.count && BundleIDs.isComponent(id, of: $0) }.map { root[$0] ?? $0 } ?? id
        }
        let grouped = Dictionary(grouping: entries) { root[$0.identifier] ?? $0.identifier }
        return grouped.map { key, entries in
            OrphanGroup(key: key, entries: entries.sorted { $0.path < $1.path })
        }.sorted { $0.key < $1.key }
    }

    /// Left-overs of one vendor (`com.coccoc.Coccoc`, `com.coccoc.keystone.agent`) shown as one old app,
    /// but only for vendors with nothing installed: otherwise exclusion decides per identifier.
    static func mergeByVendor(_ groups: [OrphanGroup], installedVendors: Set<String>) -> [OrphanGroup] {
        var merged: [String: OrphanGroup] = [:]
        var order: [String] = []
        for group in groups {
            var key = group.key
            if let vendor = BundleIDs.vendorPrefix(of: group.key), !installedVendors.contains(vendor),
               !BundleIDs.sharedNamespaces.contains(vendor),
               !libraryPrefixes.contains(where: { BundleIDs.isComponent(group.key, of: $0) }) {
                key = vendor
            }
            if var existing = merged[key] {
                existing.entries += group.entries
                existing.key = min(existing.key, group.key)
                merged[key] = existing
            } else {
                merged[key] = group
                order.append(key)
            }
        }
        return order.map { merged[$0]! }
    }

    func exclusion(for group: OrphanGroup) -> (OrphanExclusion, String)? {
        let ids = Set(group.entries.map(\.identifier))
        let installedIDs = index.apps.flatMap { $0.allIDs }
        func related(_ a: String, _ b: String) -> Bool { BundleIDs.isComponent(a, of: b) || BundleIDs.isComponent(b, of: a) }

        if ids.contains(where: { BundleIDs.isApple($0) || Self.isAppleComponent($0) }) { return (.apple, group.key) }
        if ignored.contains(group.key) || ids.contains(where: { ignored.contains($0) }) { return (.ignoredByUser, group.key) }
        if let lib = ids.first(where: { id in Self.libraryPrefixes.contains { BundleIDs.isComponent(id, of: $0) } }) {
            return (.library, lib)
        }
        for id in ids {
            if let app = index.apps.first(where: { $0.allIDs.contains(id) }) { return (.installed, app.path) }
        }
        for id in ids {
            if let other = installedIDs.first(where: { related(id, $0) }) { return (.relatedToInstalled, other) }
        }
        for id in ids {
            if let other = index.runningIDs.first(where: { related(id, $0.lowercased()) }) { return (.running, other) }
        }
        for id in ids {
            for (lsID, paths) in index.launchServices where related(id, lsID) {
                if let existing = paths.first(where: { fileSystem.exists($0) }) { return (.launchServicesKnown, existing) }
                if let first = paths.first { return (.maybeOnUnpluggedDisk, first) }
            }
        }
        for id in ids {
            if let pkg = index.livePackageIDs.first(where: { related(id, $0.lowercased()) }) { return (.packageInstalled, pkg) }
        }
        for id in ids {
            // `homebrew.mxcl.mysql`, `org.swift.swiftpm`, `org.apache.jmeter`: a part of the identifier
            // is the name of a tool that is still installed.
            let parts = id.split(separator: ".").dropFirst().map(String.init)
            if let tool = parts.first(where: { $0.count >= 3 && index.commandLineTools.contains($0) }) {
                return (.commandLineTool, tool)
            }
        }
        let teams = Set(index.apps.compactMap(\.teamID))
        for entry in group.entries {
            let name = Paths.lastComponent(entry.path)
            if let team = BundleIDs.splitTeamPrefix(BundleIDs.stripFileSuffix(name))?.team, teams.contains(team) {
                return (.sameVendorInstalled, "team \(team)")
            }
        }
        let vendors = Set(index.apps.compactMap(\.vendorPrefix))
        for id in ids {
            if let vendor = BundleIDs.vendorPrefix(of: id), vendors.contains(vendor), !BundleIDs.sharedNamespaces.contains(vendor) {
                return (.sameVendorInstalled, vendor)
            }
        }
        if now.timeIntervalSince(group.lastModified) < recentInterval {
            return (.recentlyModified, ISO8601DateFormatter().string(from: group.lastModified))
        }
        return nil
    }

    /// A name-only folder is left alone when its name, or a word in it, is anything still here.
    func nameExclusion(_ entry: OrphanEntry) -> (OrphanExclusion, String)? {
        let name = entry.identifier
        let lower = name.lowercased()
        if ignored.contains(name) { return (.ignoredByUser, name) }
        if Self.appleFolderNames.contains(lower) || Self.looksLikeDaemon(name) { return (.apple, name) }
        var known = index.launchServicesNames.union(index.commandLineTools)
        for app in index.apps {
            known.formUnion((app.names + [app.executableName].compactMap { $0 }).map { $0.lowercased() })
            if let vendor = app.vendorPrefix?.split(separator: ".").last { known.insert(String(vendor)) }
        }
        // The last part of every installed identifier: `Codex` for an installed `com.openai.codex`.
        for id in index.apps.flatMap(\.allIDs) { if let last = id.split(separator: ".").last, last.count >= 3 { known.insert(String(last)) } }
        if known.contains(lower) || Self.devToolFolders.contains(lower) { return (.knownName, name) }
        // `ChatGPTHelper` for ChatGPT.
        let squashed = Self.squash(name)
        if let app = index.apps.flatMap(\.names).map(Self.squash).first(where: { $0.count >= 4 && squashed.hasPrefix($0) }) {
            return (.knownName, app)
        }
        if let word = Self.words(name).first(where: { $0.count >= 3 && !GenericNames.isGeneric($0) && known.contains($0) }) {
            return (.knownName, word)
        }
        if Self.libraryFolderNames.contains(where: { lower.contains($0) }) { return (.library, name) }
        return nil
    }

    static func words(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: { " -_.".contains($0) }).map(String.init)
    }

    static func squash(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func lastIDComponentSquashed(_ id: String) -> String {
        squash(String(id.split(separator: ".").last ?? ""))
    }

    /// `contactsd`, `tipsd`, `icloudmailagent`: Apple's per-daemon folders are a single lower-case word.
    static func looksLikeDaemon(_ name: String) -> Bool {
        guard name == name.lowercased(), name.allSatisfy({ $0.isLetter }) else { return false }
        return name.hasSuffix("d") || name.hasSuffix("agent")
    }

    /// `groups.com.apple.podcasts` and similar Apple variants not caught by the `com.apple.` prefix,
    /// and identifiers Apple inherited (`is.workflow` is Shortcuts).
    public static func isAppleComponent(_ id: String) -> Bool {
        let l = id.lowercased()
        if appleInherited.contains(where: { BundleIDs.isComponent(l, of: $0) }) { return true }
        let parts = l.split(separator: ".")
        return zip(parts, parts.dropFirst()).contains { $0 == "com" && $1 == "apple" }
    }

    static let appleInherited = ["is.workflow"]

    /// Frameworks that name their caches and settings after themselves, inside whatever app uses
    /// them. Their data says nothing about which app wrote it.
    static let libraryPrefixes = [
        "com.onevcat.kingfisher", "com.hackemist.sdimagecache", "com.segment", "com.crashlytics",
        "io.sentry", "com.firebase", "com.google.firebase", "com.bugsnag", "com.amplitude", "com.mixpanel",
        "org.sparkle-project", "com.plausiblelabs", "com.microsoft.appcenter", "com.github.electron",
        "com.squirrel", "com.pinterest.pincache", "org.cocoapods",
    ]

    /// Caches of developer tools, kept whether or not the tool is on the PATH folders we look at.
    static let devToolFolders: Set<String> = [
        "homebrew", "yarn", "npm", "pnpm", "pip", "pipenv", "poetry", "typescript", "node", "deno", "bun", "go-build",
        "gradle", "maven", "cocoapods", "carthage", "jetbrains", "pypoetry", "uv", "ruff", "rustup", "cargo", "composer",
    ]

    static let libraryFolderNames = ["sentry", "segment", "firestore", "firebase", "crashpad", "statsig", "heartbeat",
                                     "nodejs", "node-gyp", "playwright", "electron", "squirrel", "sparkle", "datadog"]

    /// Folders macOS itself keeps in Application Support, Caches and Logs, named without an identifier.
    static let appleFolderNames: Set<String> = [
        "addressbook", "animoji", "app store", "callhistorydb", "callhistorytransactions", "clouddocs", "controlcenter",
        "crashreporter", "differentialprivacy", "diskimages", "facetime", "fileprovider", "intelligenceflow", "knowledge",
        "mobilesync", "music", "spotlight", "syncservices", "icloud", "amsdatamigratortool", "cloudkit", "familycircle",
        "gamekit", "geoservices", "passkit", "jetpackcache", "installation", "appanalytics", "assistant", "baseband",
        "diagnosticreports", "privacypreservingmeasurement", "sirittsservice", "sync", "accounts", "dock",
        "photossearch", "photosupgrade", "quick look", "safari", "siri", "wallpaper", "sharedfilelist", "tv", "podcasts",
        "news", "stocks", "weather", "maps", "books", "messages", "mail", "notes", "reminders", "calendars", "contacts",
        "homekit", "screen time", "screentime", "keyboard", "dictionary", "installer_telemetry",
        "apple", "metadata", "mobiledevice", "ubiquity", "coresimulator",
    ]

    /// The newest modification time of an entry and its direct children: a folder's own date only
    /// changes when its direct contents change.
    func latestModification(_ path: String, info: FileInfo) -> Date {
        guard info.type == .directory, let children = try? fileSystem.contents(ofDirectory: path) else { return info.modified }
        return children.prefix(500).compactMap { try? fileSystem.info(Paths.join(path, $0)).modified }
            .reduce(info.modified, max)
    }
}
