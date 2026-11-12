import Foundation

/// An installer package receipt (`pkgutil --pkgs` / `--files`).
public struct PackageReceipt: Sendable, Hashable {
    public var id: String
    /// Paths installed by the package, relative to its volume (`Applications/Foo.app`).
    public var files: [String]

    public init(id: String, files: [String]) {
        self.id = id
        self.files = files
    }
}

/// Names that say nothing about which app they belong to. A folder with one of these names is only
/// ever a low-confidence match, however exactly it equals the app's name.
public enum GenericNames {
    public static let all: Set<String> = [
        "mail", "code", "notes", "music", "photos", "calendar", "messages", "maps", "preview", "terminal",
        "console", "books", "news", "stocks", "weather", "clock", "reminders", "contacts", "safari",
        "adobe", "google", "microsoft", "apple", "electron", "helper", "updater", "update", "cache",
        "caches", "data", "logs", "log", "shared", "common", "documents", "downloads", "desktop",
        "library", "application", "applications", "app", "apps", "settings", "preferences", "config",
        "plugins", "extensions", "temp", "tmp", "crashpad", "sentry", "squirrel", "default", "user",
        "users", "local", "storage", "backup", "backups", "sync", "agent", "daemon", "service",
        "chat", "editor", "player", "browser", "launcher", "studio", "office", "teams", "drive",
    ]

    public static func isGeneric(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.count < 3 || all.contains(l)
    }
}

/// Uninstall mode: finds everything that belongs to one app.
public struct Scanner: Sendable {
    public var fileSystem: FileSystem
    public var locations: [Location]
    /// Every other installed app. Used to avoid taking their data and to flag shared data.
    public var otherApps: [AppIdentity]
    public var receipts: [PackageReceipt]
    /// Identifier → paths from LaunchServices (see `InstalledAppIndex.launchServices`).
    public var launchServices: [String: [String]]
    /// The user running the scan. Items owned by anyone else need an administrator to move.
    public var userID: UInt32?

    public init(fileSystem: FileSystem, locations: [Location], otherApps: [AppIdentity], receipts: [PackageReceipt] = [],
                launchServices: [String: [String]] = [:], userID: UInt32? = nil) {
        self.fileSystem = fileSystem
        self.locations = locations
        self.otherApps = otherApps
        self.receipts = receipts
        self.launchServices = launchServices
        self.userID = userID
    }

    public struct Result: Sendable {
        public var findings: [Finding]
        /// Locations that could not be read, with the reason. Shown to the user, never silently dropped.
        public var unreadable: [(path: String, error: FileSystemError)]
    }

    public func scan(_ app: AppIdentity) -> Result {
        var findings = [Finding(path: app.path, kind: .appBundle, domain: .user, confidence: .high, reason: .appBundle)]
        var unreadable: [(String, FileSystemError)] = []
        let others = otherApps.filter { $0.bundleID.lowercased() != app.bundleID.lowercased() }

        for location in locations {
            let names: [String]
            do {
                names = try fileSystem.contents(ofDirectory: location.path)
            } catch let error as FileSystemError {
                if case .notFound = error { continue }
                unreadable.append((location.path, error))
                continue
            } catch {
                unreadable.append((location.path, .other(location.path, "\(error)")))
                continue
            }
            for name in names.sorted() {
                let path = Paths.join(location.path, name)
                if let match = matchEntry(name, path: path, in: location, app: app, others: others) {
                    findings.append(Finding(path: path, kind: location.kind, domain: location.domain,
                                            confidence: match.confidence, reason: match.reason, sharedWith: match.sharedWith))
                } else if location.kind == .userData || location.kind == .cache || location.kind == .log,
                          let vendorWord = vendorWord(app), name.lowercased() == vendorWord,
                          fileSystem.isDirectory(path) {
                    // Vendor folder (`Application Support/Google`): look one level in for the app's own folder.
                    findings += vendorFolderMatches(path, location: location, app: app, others: others)
                }
            }
        }
        for i in findings.indices where !findings[i].path.hasPrefix("pkgutil:") {
            findings[i].domain = Ownership.domain(of: findings[i].path, default: findings[i].domain, fileSystem: fileSystem, userID: userID)
        }
        findings += receiptMatches(app)
        return Result(findings: findings, unreadable: unreadable)
    }

    struct Match {
        var confidence: Confidence
        var reason: MatchReason
        var sharedWith: [String] = []
    }

    func matchEntry(_ name: String, path: String, in location: Location, app: AppIdentity, others: [AppIdentity]) -> Match? {
        let stripped = BundleIDs.stripFileSuffix(name)

        if let match = matchIdentifier(stripped, app: app, others: others) { return match }

        if location.kind == .launchItem, name.hasSuffix(".plist"), let program = launchItemProgram(path),
           program.hasPrefix(app.path + "/") {
            return Match(confidence: .high, reason: .launchItemProgram(program))
        }

        if !BundleIDs.looksLikeBundleID(stripped) {
            return matchName(stripped, app: app, others: others)
        }
        return nil
    }

    /// Matches an identifier-shaped name: bundle ID, its components, nested bundles, app groups,
    /// and other identifiers from the same vendor when no other app of that vendor is installed.
    func matchIdentifier(_ raw: String, app: AppIdentity, others: [AppIdentity]) -> Match? {
        let team = BundleIDs.splitTeamPrefix(raw)
        let id = BundleIDs.dropHardwareUUID(BundleIDs.stripGroupPrefix(team?.rest ?? raw))

        // A group container's folder is named exactly after the group identifier.
        for group in app.appGroups {
            let g = group.lowercased()
            if raw.lowercased() == g {
                let sharers = others.filter { $0.appGroups.contains { $0.lowercased() == g } }.map(\.displayName)
                return Match(confidence: .high, reason: .appGroup(group), sharedWith: sharers)
            }
        }

        // The most specific owner wins: `com.foo.Bar.Pro` belongs to an installed Bar Pro, not to
        // Bar. "Installed" includes apps LaunchServices knows that the folder scan did not find.
        let ownID = bestComponentMatch(id, ids: [app.bundleID] + app.nestedBundleIDs)
        let otherIDs = others.flatMap { [$0.bundleID] + $0.nestedBundleIDs } + otherLaunchServicesIDs(app)
        let otherID = bestComponentMatch(id, ids: otherIDs)

        if let own = ownID {
            if let otherID, otherID.count > own.count { return nil }
            // A team-prefixed container for this ID is the app's own unless the team differs.
            if let team, let appTeam = app.teamID, team.team != appTeam { return nil }
            let reason: MatchReason
            if own.lowercased() == app.bundleID.lowercased() {
                reason = id.lowercased() == own.lowercased() ? .bundleID(own) : .bundleIDComponent(own)
            } else {
                reason = .nestedBundleID(own)
            }
            // `com.foo.Bar.ShipIt` is almost surely Bar's; `com.foo.Bar.for.testing` may be another app.
            let extra = id.split(separator: ".").count - own.split(separator: ".").count
            return Match(confidence: extra <= 1 ? .high : .medium, reason: reason)
        }

        // Same vendor (`com.docker.vmnetd` for `com.docker.docker`), only when no other app of
        // that vendor is installed: otherwise it may well be theirs, and is not shown at all.
        if otherID == nil, BundleIDs.looksLikeBundleID(id), let vendor = BundleIDs.vendorPrefix(of: id),
           vendor == app.vendorPrefix, !BundleIDs.sharedNamespaces.contains(vendor), !BundleIDs.isApple(vendor),
           !others.contains(where: { $0.vendorPrefix == vendor }) {
            if let team, let appTeam = app.teamID, team.team != appTeam { return nil }
            return Match(confidence: .medium, reason: .sameVendor(vendor))
        }
        return nil
    }

    /// Identifiers LaunchServices registered for apps other than this one (anywhere outside its bundle).
    func otherLaunchServicesIDs(_ app: AppIdentity) -> [String] {
        let own = app.allIDs
        return launchServices.compactMap { id, paths in
            if own.contains(id.lowercased()) { return nil }
            return paths.allSatisfy({ $0.hasPrefix(app.path + "/") }) ? nil : id
        }
    }

    func bestComponentMatch(_ id: String, ids: [String]) -> String? {
        ids.filter { BundleIDs.isComponent(id, of: $0) }.max { $0.count < $1.count }
    }

    /// Matches a plain folder name (`Slack`, `Code`) against the app's names. Never better than medium.
    func matchName(_ name: String, app: AppIdentity, others: [AppIdentity]) -> Match? {
        let l = name.lowercased()
        let candidates = Set((app.names + [app.executableName].compactMap { $0 }).map { $0.lowercased() })
        guard candidates.contains(l) else {
            // `Docker Desktop`, `docker-secrets-engine` for Docker: plausible, but only ever low.
            let prefixed = candidates.first { c in !GenericNames.isGeneric(c) && (l.hasPrefix(c + " ") || l.hasPrefix(c + "-")) }
            return prefixed.map { _ in Match(confidence: .low, reason: .name(name)) }
        }
        let clash = others.filter { other in
            (other.names + [other.executableName].compactMap { $0 }).contains { $0.lowercased() == l }
        }
        let confidence: Confidence = GenericNames.isGeneric(l) || !clash.isEmpty ? .low : .medium
        return Match(confidence: confidence, reason: .name(name), sharedWith: clash.map(\.displayName))
    }

    /// `com.google.Chrome` → `google`.
    func vendorWord(_ app: AppIdentity) -> String? {
        // Apple's folders (`Application Support/Apple`) are never one app's.
        if BundleIDs.isApple(app.bundleID) { return nil }
        let parts = app.bundleID.lowercased().split(separator: ".")
        return parts.count >= 3 ? String(parts[1]) : nil
    }

    func vendorFolderMatches(_ folder: String, location: Location, app: AppIdentity, others: [AppIdentity]) -> [Finding] {
        guard let vendor = vendorWord(app), let children = try? fileSystem.contents(ofDirectory: folder) else { return [] }
        // "Google Chrome" inside "Google" is "Chrome".
        let shortNames = app.names.map { name -> String in
            let words = name.split(separator: " ")
            if words.count > 1, words[0].lowercased() == vendor { return words.dropFirst().joined(separator: " ") }
            return name
        }
        var short = app
        short.names = app.names + shortNames
        return children.sorted().compactMap { child in
            guard let match = matchName(child, app: short, others: others) else { return nil }
            return Finding(path: Paths.join(folder, child), kind: location.kind, domain: location.domain,
                           confidence: match.confidence, reason: match.reason, sharedWith: match.sharedWith)
        }
    }

    func launchItemProgram(_ path: String) -> String? {
        guard let data = try? fileSystem.readFile(path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        if let program = plist["Program"] as? String { return program }
        return (plist["ProgramArguments"] as? [String])?.first
    }

    func receiptMatches(_ app: AppIdentity) -> [Finding] {
        let relative = app.path.hasPrefix("/") ? String(app.path.dropFirst()) : app.path
        return receipts.compactMap { receipt in
            if BundleIDs.isComponent(receipt.id, of: app.bundleID) || receipt.files.contains(relative) {
                return Finding(path: "pkgutil:" + receipt.id, kind: .receipt, domain: .system,
                               confidence: .high, reason: .receipt(receipt.id))
            }
            return nil
        }
    }
}

public extension AppIdentity {
    var displayName: String { names.first ?? bundleID }
}
