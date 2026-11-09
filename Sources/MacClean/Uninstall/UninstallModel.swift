import UninstallCore
import UninstallSystem
import AppKit
import Foundation

/// One line in a list: a finding (uninstall mode) or a left-over entry (clean-up mode).
struct Row: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var kind: DataKind
    var domain: Domain
    var confidence: Confidence
    var reason: String
    var sharedWith: [String]
    var modified: Date?
}

/// A titled list of rows with one checkbox for all of them.
struct RowGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var rows: [Row]
    var warning: String?
    var canIgnore = false
}

struct Confirmation: Identifiable {
    let id = UUID()
    var plan: DeletionPlan
    var findings: [Finding]
    var runningApps: [String]
    var userDataCount: Int
    var launchAgentCount: Int
}

struct ActionReport: Identifiable {
    let id = UUID()
    var trashed: [TrashRecord]
    var receiptsForgotten: Int
    var problems: [(path: String, message: String)]
    var deletedPermanently: [TrashRecord]? = nil
    var permanentProblems: [(path: String, message: String)] = []
    var trashedBytes: UInt64 { trashed.reduce(0) { $0 + $1.bytes } }
}

@MainActor
final class UninstallModel: ObservableObject {
    enum Mode: String, CaseIterable { case uninstall, leftovers }

    let env: CleanerEnvironment

    @Published var mode: Mode = .uninstall
    @Published var hasFullDiskAccess = true
    @Published var dropTargeted = false
    @Published var message: String?

    // Uninstall mode
    @Published var target: AppIdentity?
    @Published var findings: [Finding] = []
    @Published var scanning = false
    // Clean-up mode
    @Published var orphans: OrphanFinder.Result?
    @Published var orphanScanning = false
    @Published var filter = ""
    @Published var showUncertain = false
    @Published var showUnknown = false
    @Published var orphanFindings: [Finding] = []

    // Shared
    @Published var unreadable: [String] = []
    @Published var selected: Set<String> = []
    @Published var sizes: [String: UInt64] = [:]
    @Published var sizing = false
    @Published var modified: [String: Date] = [:]
    @Published var confirmation: Confirmation?
    @Published var report: ActionReport?

    private var index: (apps: [AppIdentity], receipts: [PackageReceipt], made: Date)?
    private var scanTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private let cancelFlag = UninstallCancelFlag()
    private var ignoreList: IgnoreList

    init(env: CleanerEnvironment) {
        self.env = env
        ignoreList = env.loadIgnoreList()
        refreshPermissions()
    }

    /// Full Disk Access granted while the app runs only applies to the next launch, so the banner
    /// offers to restart. Only for a real .app bundle (a `swift run` build has nothing to reopen).
    var canRelaunch: Bool { env.selfBundlePath != nil }

    func relaunch() {
        guard let path = env.selfBundlePath else { return }
        // A small shell outlives this process, waits for it to quit, then opens the app again.
        // The path is passed as an argument ($1), never pasted into the command.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$2\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
                             "sh", path, String(ProcessInfo.processInfo.processIdentifier)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    func refreshPermissions() {
        hasFullDiskAccess = env.isSandbox || Permissions.hasFullDiskAccess(home: env.home)
    }

    // MARK: Uninstall mode

    /// Accepts a dropped or chosen item. Anything that is not an .app bundle is refused with a message.
    func open(_ url: URL) {
        mode = .uninstall
        guard url.pathExtension == "app" else {
            message = L("Only apps (.app) can be dropped here.")
            return
        }
        let env = self.env
        // The real path: a dropped alias or a path through a symbolic link (/tmp → /private/tmp)
        // would otherwise be refused later by the safety policy.
        // (`realpath`, not `resolvingSymlinksInPath`, which strips /private and so makes it worse.)
        let path = (try? env.fileSystem.canonicalPath(url.path)) ?? url.standardizedFileURL.path
        guard let identity = BundleReader.identity(ofAppAt: path) else {
            message = L("This app's information could not be read.")
            return
        }
        if let selfPath = env.selfBundlePath, path == selfPath || identity.bundleID == env.selfBundleID {
            message = L("To remove Mac Clean, use “Uninstall Mac Clean…” in its menu.")
            return
        }
        if BundleIDs.isApple(identity.bundleID) || path.hasPrefix("/System/") {
            message = L("Apps that come with macOS can't be removed.")
            return
        }
        message = nil
        refreshPermissions()
        target = identity
        findings = []
        selected = []
        sizes = [:]
        report = nil
        scanning = true
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let (apps, receipts) = await self.installedIndex()
            let ls = await Task.detached { env.launchServices().ids }.value
            let result = await Task.detached {
                Scanner(fileSystem: env.fileSystem, locations: env.locations, otherApps: apps, receipts: receipts,
                        launchServices: ls, userID: getuid()).scan(identity)
            }.value
            guard !Task.isCancelled, self.target == identity else { return }
            self.findings = result.findings
            self.unreadable = result.unreadable.map(\.path)
            self.selected = Set(result.findings.filter(\.preselectedForUninstall).map(\.path))
            self.scanning = false
            self.computeSizes(result.findings.map(\.path))
        }
    }

    /// Back to the drop box: forgets the app and everything found for it. Nothing is removed.
    func clearTarget() {
        scanTask?.cancel()
        sizeTask?.cancel()
        target = nil
        findings = []
        selected = []
        sizes = [:]
        unreadable = []
        scanning = false
        sizing = false
        report = nil
        message = nil
    }

    var uninstallGroups: [RowGroup] {
        let order: [(String, (Finding) -> Bool, String?)] = [
            (L("App"), { $0.kind == .appBundle },
             findings.contains { $0.kind == .appBundle && $0.domain == .system }
                ? L("This app belongs to the system (for example, installed from the App Store), so macOS will ask for an administrator password to move it.") : nil),
            (L("App data"), { $0.domain == .user && $0.kind == .userData },
             L("May contain your own data (documents, saves, databases, licences).")),
            (L("Settings"), { $0.domain == .user && [.preferences, .savedState].contains($0.kind) }, nil),
            (L("Caches and logs"), { $0.domain == .user && [.cache, .log, .webData].contains($0.kind) }, nil),
            (L("Launch items and scripts"), { $0.domain == .user && [.launchItem, .scripts, .helper].contains($0.kind) }, nil),
            (L("System-wide (administrator password needed)"), { $0.domain == .system },
             L("Shared by all users of this Mac. macOS asks for an administrator password.")),
        ]
        var used = Set<String>()
        return order.compactMap { title, test, warning in
            let rows = findings.filter { !used.contains($0.path) && test($0) }
            rows.forEach { used.insert($0.path) }
            guard !rows.isEmpty else { return nil }
            return RowGroup(id: title, title: title, rows: rows.map(row(for:)), warning: warning)
        }
    }

    func row(for f: Finding) -> Row {
        var reason = describe(f.reason)
        if !f.sharedWith.isEmpty { reason += " · " + String(format: L("may be shared with %@"), f.sharedWith.joined(separator: ", ")) }
        return Row(path: f.path, kind: f.kind, domain: f.domain, confidence: f.confidence, reason: reason,
                   sharedWith: f.sharedWith, modified: modified[f.path])
    }

    func describe(_ reason: MatchReason) -> String {
        switch reason {
        case .appBundle: L("the app itself")
        case .bundleID(let id): String(format: L("bundle ID %@"), id)
        case .bundleIDComponent(let id): String(format: L("part of %@"), id)
        case .nestedBundleID(let id): String(format: L("helper or extension %@"), id)
        case .appGroup(let g): String(format: L("app group %@"), g)
        case .sameVendor(let v): String(format: L("same developer (%@), none of their other apps installed"), v)
        case .name(let n): String(format: L("folder name “%@”"), n)
        case .launchItemProgram(let p): String(format: L("starts %@"), p)
        case .receipt(let r): String(format: L("installer receipt %@"), r)
        }
    }

    // MARK: Clean-up mode

    func scanLeftovers() {
        refreshPermissions()
        mode = .leftovers
        orphanScanning = true
        orphans = nil
        orphanFindings = []
        selected = []
        sizes = [:]
        report = nil
        cancelFlag.reset()
        let env = self.env
        let flag = cancelFlag
        let ignored = ignoreList
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let (apps, receipts) = await self.installedIndex()
            let result = await Task.detached {
                let index = env.installedIndex(apps: apps, receipts: receipts)
                return OrphanFinder(fileSystem: env.fileSystem, locations: env.locations, index: index, ignored: ignored,
                                    isCancelled: { flag.isSet }).find()
            }.value
            self.orphanScanning = false
            guard !result.cancelled else { self.orphans = nil; return }
            self.orphans = result
            self.unreadable = result.unreadable.map(\.path)
            self.orphanFindings = self.findings(from: result)
            // Nothing is ticked in clean-up mode: the user chooses.
            self.selected = []
            self.computeSizes(self.orphanFindings.map(\.path))
        }
    }

    func cancelScan() {
        cancelFlag.set()
        sizeTask?.cancel()
    }

    private func findings(from result: OrphanFinder.Result) -> [Finding] {
        let all = result.groups + result.uncertain.map(\.group) + result.unknownOwner
        return all.flatMap(\.entries).map { entry in
            let isID = OrphanFinder.identifier(fromEntry: Paths.lastComponent(entry.path)) != nil
            let domain = Ownership.domain(of: entry.path, default: .user, fileSystem: env.fileSystem, userID: getuid())
            return Finding(path: entry.path, kind: entry.kind, domain: domain, confidence: entry.confidence,
                           reason: isID ? .bundleID(entry.identifier) : .name(entry.identifier))
        }
    }

    var leftoverGroups: [RowGroup] {
        guard let orphans else { return [] }
        var groups = orphans.groups.map { group(for: $0, warning: nil) }
        if showUncertain {
            groups += orphans.uncertain.map {
                group(for: $0.group, warning: String(format: L("Not sure: %@ still has an app installed that may use this."), $0.detail))
            }
        }
        if showUnknown {
            groups += orphans.unknownOwner.map {
                group(for: $0, warning: L("Not sure: no app could be matched to this folder."))
            }
        }
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            groups = groups.filter { g in
                g.title.lowercased().contains(query) || g.rows.contains { $0.path.lowercased().contains(query) }
            }
        }
        return groups.sorted { total($0) > total($1) }
    }

    private func group(for g: OrphanGroup, warning: String?) -> RowGroup {
        let rows = g.entries.map { entry in
            Row(path: entry.path, kind: entry.kind,
                domain: orphanFindings.first { $0.path == entry.path }?.domain ?? .user, confidence: entry.confidence,
                reason: entry.linkReason.map { String(format: L("folder name matches (%@)"), $0) } ?? "",
                sharedWith: [], modified: entry.modified)
        }
        var warnings = [warning].compactMap { $0 }
        if g.mayHoldUserData { warnings.append(L("May contain your own data (documents, saves, databases, licences).")) }
        return RowGroup(id: g.key, title: g.key, subtitle: String(format: L("last changed %@"), Self.date(g.lastModified)),
                        rows: rows, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "), canIgnore: true)
    }

    func ignore(_ group: RowGroup) {
        ignoreList.add(group.id)
        env.saveIgnoreList(ignoreList)
        for row in group.rows { selected.remove(row.path) }
        guard var result = orphans else { return }
        result.groups.removeAll { $0.key == group.id }
        result.uncertain.removeAll { $0.group.key == group.id }
        result.unknownOwner.removeAll { $0.key == group.id }
        orphans = result
    }

    var ignoredCount: Int { ignoreList.keys.count }

    func clearIgnoreList() {
        ignoreList = IgnoreList()
        env.saveIgnoreList(ignoreList)
    }

    // MARK: Selection

    var visibleGroups: [RowGroup] { mode == .uninstall ? uninstallGroups : leftoverGroups }

    func isSelected(_ path: String) -> Bool { selected.contains(path) }

    func setSelected(_ path: String, _ on: Bool) {
        if on { selected.insert(path) } else { selected.remove(path) }
    }

    enum GroupState { case none, some, all }

    func state(of group: RowGroup) -> GroupState {
        let n = group.rows.filter { selected.contains($0.path) }.count
        return n == 0 ? .none : n == group.rows.count ? .all : .some
    }

    func toggle(_ group: RowGroup) {
        let on = state(of: group) != .all
        for row in group.rows { setSelected(row.path, on) }
    }

    /// Ticked rows that are on screen right now. Hidden sections never count.
    var selectedVisiblePaths: Set<String> {
        Set(visibleGroups.flatMap(\.rows).map(\.path)).intersection(selected)
    }

    var selectedBytes: UInt64 { selectedVisiblePaths.reduce(0) { $0 + (sizes[$1] ?? 0) } }

    func total(_ group: RowGroup) -> UInt64 { group.rows.reduce(0) { $0 + (sizes[$1.path] ?? 0) } }

    /// Everything found for the app being removed, ticked or not.
    var foundBytes: UInt64 { findings.reduce(0) { $0 + (sizes[$1.path] ?? 0) } }

    /// Everything the clean-up list shows right now.
    var leftoverBytes: UInt64 { leftoverGroups.reduce(0) { $0 + total($1) } }

    /// Ticks every visible row. Rows that cannot be removed are refused later by the safety policy.
    func selectAllVisible() {
        for group in visibleGroups { for row in group.rows { selected.insert(row.path) } }
    }

    func clearSelection() { selected = [] }

    // MARK: Sizes

    private func computeSizes(_ paths: [String]) {
        sizeTask?.cancel()
        sizing = true
        let fs = env.fileSystem
        sizeTask = Task { [weak self] in
            let results = await Task.detached { () -> [(String, UInt64, Date?)] in
                var seen = Set<[UInt64]>()
                let calculator = SizeCalculator(fileSystem: fs)
                return paths.map { path in
                    if path.hasPrefix("pkgutil:") { return (path, 0, nil) }
                    let totals = calculator.size(of: [path], seen: &seen, isCancelled: { Task.isCancelled })
                    return (path, totals.bytes, try? fs.info(path).modified)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            for (path, bytes, date) in results {
                self.sizes[path] = bytes
                if let date, self.modified[path] == nil { self.modified[path] = date }
            }
            self.sizing = false
        }
    }

    // MARK: Acting

    /// Builds the plan from the ticked, visible rows and asks for confirmation.
    func requestRemoval() {
        let source = mode == .uninstall ? findings : orphanFindings
        let plan = DeletionPlan.make(findings: source, selected: selectedVisiblePaths, sizes: sizes, policy: env.policy)
        var running: [String] = []
        if mode == .uninstall, let target {
            running = RunningApps().running(among: [target.bundleID] + target.nestedBundleIDs)
        }
        let plannedPaths = Set(plan.items.map(\.displayPath))
        let planned = source.filter { plannedPaths.contains($0.path) }
        confirmation = Confirmation(plan: plan, findings: planned, runningApps: running,
                                    userDataCount: planned.filter { $0.kind.mayHoldUserData }.count,
                                    launchAgentCount: planned.filter { $0.kind == .launchItem }.count)
    }

    func recheckRunning() {
        guard let c = confirmation, let target else { return }
        var updated = c
        updated.runningApps = RunningApps().running(among: [target.bundleID] + target.nestedBundleIDs)
        confirmation = updated
    }

    func quitRunningApps() {
        guard let c = confirmation else { return }
        RunningApps.requestQuit(c.runningApps)
    }

    func performConfirmed() {
        guard let c = confirmation, c.runningApps.isEmpty else { return }
        confirmation = nil
        let env = self.env
        let plan = c.plan
        Task { [weak self] in
            let outcomes = await Task.detached {
                Remover(policy: env.policy, trasher: env.trasher, admin: env.admin, launchAgents: env.launchAgents,
                        log: env.log, trashFolder: env.trashFolder).execute(plan, includeAdmin: true)
            }.value
            guard let self else { return }
            var report = ActionReport(trashed: [], receiptsForgotten: 0, problems: [])
            for outcome in outcomes {
                switch outcome.status {
                case .trashed(let record): report.trashed.append(record)
                case .receiptForgotten: report.receiptsForgotten += 1
                case .skipped(let why), .failed(let why): report.problems.append((outcome.path, why))
                }
            }
            for problem in plan.rejected { report.problems.append((problem.path, problem.reason)) }
            self.report = report
            self.afterRemoval(removed: Set(report.trashed.map(\.original)))
        }
    }

    private func afterRemoval(removed: Set<String>) {
        selected.subtract(removed)
        if mode == .uninstall {
            findings.removeAll { removed.contains($0.path) }
            if let target, removed.contains(target.path) { index = nil }
        } else if var result = orphans {
            func keep(_ g: OrphanGroup) -> OrphanGroup? {
                var g = g
                g.entries.removeAll { removed.contains($0.path) }
                return g.entries.isEmpty ? nil : g
            }
            result.groups = result.groups.compactMap(keep)
            result.unknownOwner = result.unknownOwner.compactMap(keep)
            result.uncertain = result.uncertain.compactMap { e in keep(e.group).map { OrphanFinder.Excluded(group: $0, reason: e.reason, detail: e.detail) } }
            orphans = result
            orphanFindings.removeAll { removed.contains($0.path) }
        }
    }

    /// Deletes for good exactly what this report moved to the Trash. Never anything else in the Trash.
    func deletePermanently() {
        guard var report, report.deletedPermanently == nil else { return }
        let env = self.env
        let records = report.trashed
        Task { [weak self] in
            let outcomes = await Task.detached {
                PermanentDeleter(fileSystem: env.fileSystem, remover: env.permanentRemover, admin: env.adminRemover,
                                 userID: getuid(), trashFolders: env.trashFolders, log: env.log).delete(records)
            }.value
            report.deletedPermanently = outcomes.filter { $0.error == nil }.map(\.record)
            report.permanentProblems = outcomes.compactMap { o in o.error.map { (o.record.trashed, $0) } }
            self?.report = report
        }
    }

    /// How many of the trashed items belong to the system and so need a password to delete.
    var permanentAdminCount: Int {
        guard let report else { return 0 }
        return PermanentDeleter(fileSystem: env.fileSystem, remover: env.permanentRemover, userID: getuid(),
                                trashFolders: env.trashFolders).needingAdmin(report.trashed).count
    }

    // MARK: Index of installed apps (cached for a few minutes)

    private func installedIndex() async -> ([AppIdentity], [PackageReceipt]) {
        if let index, Date().timeIntervalSince(index.made) < 300 { return (index.apps, index.receipts) }
        let env = self.env
        let (apps, receipts) = await Task.detached { (env.installedApps(), env.receipts()) }.value
        index = (apps, receipts, Date())
        return (apps, receipts)
    }

    static func date(_ d: Date) -> String {
        d == .distantPast ? "—" : d.formatted(date: .abbreviated, time: .omitted)
    }

    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}

/// A flag a background scan polls to stop early.
final class UninstallCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
    func reset() { lock.withLock { value = false } }
}
