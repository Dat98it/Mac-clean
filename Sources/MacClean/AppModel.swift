import AppKit
import Foundation
import MacCleanCore
import MacCleanSystem

/// Interface text. The English text is the key; vi.lproj/Localizable.strings holds the Vietnamese.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// A reason from Core ("inside protected folder /x"), translated: the fixed part is the key, a
/// path after it is kept as is.
func R(_ reason: String) -> String {
    for prefix in ["inside protected folder ", "contains protected folder ", "in use by ", "path goes through a symbolic link "] where reason.hasPrefix(prefix) {
        return L(String(prefix.dropLast())) + " " + reason.dropFirst(prefix.count)
    }
    return L(reason)
}

enum Format {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(b, UInt64(Int64.max))), countStyle: .file)
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func count(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}

/// Batches handed over by scanning threads, taken by the main thread a few times a second.
final class BatchQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ScanBatch] = []

    func push(_ batch: ScanBatch) {
        lock.lock(); pending.append(batch); lock.unlock()
    }

    func drain() -> [ScanBatch] {
        lock.lock(); defer { lock.unlock() }
        let taken = pending
        pending = []
        return taken
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// One volume's scan: its tree, what is ticked, and how far it got.
@MainActor
final class ScanSession {
    enum State: Equatable {
        case scanning
        case finished
        case cancelled
        /// The disk was unplugged: the tree stays for viewing, nothing can be removed.
        case volumeGone
    }

    let volume: Volume
    let store: NodeStore
    var state: State = .scanning
    var summary: ScanSummary?
    let started = Date()
    var finishedAt: Date?
    let queue = BatchQueue()
    let cancelFlag = CancelFlag()
    /// Ticked nodes, kept minimal: never a node together with one of its ancestors.
    var ticked = Set<NodeID>()
    /// Safety verdicts of nodes shown so far (the policy reads the disk, so it is asked once per node).
    var verdicts: [NodeID: SafetyPolicy.Verdict] = [:]

    init(volume: Volume, store: NodeStore) {
        self.volume = volume
        self.store = store
    }

    var isScanning: Bool { state == .scanning }
}

/// Everything the window and the menu bar show, and every action they take. Decisions are made in
/// Core; this only wires them to the machine and keeps state for the interface.
@MainActor
final class AppModel: ObservableObject {
    let env: MacCleanEnvironment
    let prefs: Preferences

    @Published private(set) var volumes: [Volume] = []
    @Published var selectedVolumeID: String?
    @Published private(set) var hasFullDiskAccess = false
    private(set) var sessions: [String: ScanSession] = [:]
    var order = SortOrder.default
    var filter = BrowseFilter()
    var intoPackages = false
    /// What this app session moved to the Trash: the only things "Delete for good" may touch.
    private(set) var lastTrashed: [TrashRecord] = []
    /// A background search reads the tree: nothing may change it meanwhile.
    var isSearching = false

    /// Called after batches were added: the parents whose children changed.
    var onTreeChanged: ((Set<NodeID>) -> Void)?
    /// Called when a scan starts, ends, or the volume list changes.
    var onStateChanged: (() -> Void)?

    private var drainTimer: Timer?

    init(env: MacCleanEnvironment, prefs: Preferences) {
        self.env = env
        self.prefs = prefs
        refreshVolumes()
        refreshPermissions()
    }

    var selectedVolume: Volume? { volumes.first { $0.id == selectedVolumeID } ?? volumes.first }
    var session: ScanSession? { selectedVolume.flatMap { sessions[$0.id] } }
    var anyScanning: Bool { sessions.values.contains { $0.isScanning } }

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
    }

    /// Re-reads mounted disks. A session whose disk disappeared keeps its tree, marked as gone.
    func refreshVolumes() {
        volumes = env.volumes()
        let present = Set(volumes.map(\.id))
        for (id, session) in sessions where !present.contains(id) && session.state != .volumeGone {
            session.cancelFlag.cancel()
            session.state = .volumeGone
        }
        if selectedVolumeID == nil || !(present.contains(selectedVolumeID!) || sessions[selectedVolumeID!] != nil) {
            selectedVolumeID = volumes.first?.id
        }
        onStateChanged?()
    }

    /// The volume list, including disks that went away while their tree is still shown.
    var listedVolumes: [Volume] {
        volumes + sessions.values.filter { s in s.state == .volumeGone && !volumes.contains { $0.id == s.volume.id } }.map(\.volume)
    }

    var policy: SafetyPolicy {
        env.policy(volumes: volumes, allowlist: prefs.allowlist)
    }

    // MARK: Scanning

    func scan(_ volume: Volume) {
        guard !isSearching else { return }
        sessions[volume.id]?.cancelFlag.cancel()
        let firmlinks = env.firmlinks(for: volume)
        let expected = Int(min(volume.filesInUse, 4_000_000))
        let store = NodeStore(rootPath: volume.scanRoot, firmlinks: firmlinks, expectedCount: volume.kind == .startupData || volume.filesInUse < 4_000_000 ? expected : 0)
        let session = ScanSession(volume: volume, store: store)
        sessions[volume.id] = session
        let excluded = hasFullDiskAccess || env.isSandbox ? [] : ScanRules.privacyExclusions(home: env.home, scanRoot: volume.scanRoot, firmlinks: firmlinks)
        let scanner = Scanner(reader: env.reader, volume: volume, threads: 8, excluded: volume.kind == .startupData ? excluded : [])
        let queue = session.queue
        let flag = session.cancelFlag
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = scanner.run(isCancelled: { flag.isCancelled }) { queue.push($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(session, summary: summary) }
            }
        }
        startDraining()
        onStateChanged?()
    }

    func cancelScan() {
        session?.cancelFlag.cancel()
    }

    private func finish(_ session: ScanSession, summary: ScanSummary) {
        drain(session)
        session.summary = summary
        session.finishedAt = Date()
        if session.state == .scanning {
            session.state = summary.volumeGone ? .volumeGone : summary.cancelled ? .cancelled : .finished
        }
        if summary.volumeGone { refreshVolumes() }
        if !anyScanning { drainTimer?.invalidate(); drainTimer = nil }
        onStateChanged?()
    }

    private func startDraining() {
        guard drainTimer == nil else { return }
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for session in self.sessions.values where session.isScanning { self.drain(session) }
            }
        }
    }

    private func drain(_ session: ScanSession) {
        let batches = session.queue.drain()
        guard !batches.isEmpty else { return }
        var touched = Set<NodeID>()
        for batch in batches where session.store.apply(batch) {
            touched.insert(batch.parent)
        }
        if session === self.session { onTreeChanged?(touched) }
    }

    // MARK: Ticking

    func verdict(_ id: NodeID, in session: ScanSession) -> SafetyPolicy.Verdict {
        if let cached = session.verdicts[id] { return cached }
        let verdict: SafetyPolicy.Verdict
        if session.state == .volumeGone {
            verdict = .denied("the volume is no longer connected")
        } else {
            verdict = policy.check(session.store.path(id))
        }
        session.verdicts[id] = verdict
        return verdict
    }

    /// The ticked node at or above `id`, if any.
    func tickedAncestor(of id: NodeID, in session: ScanSession) -> NodeID? {
        var node: NodeID? = id
        while let n = node {
            if session.ticked.contains(n) { return n }
            node = session.store.parent(of: n)
        }
        return nil
    }

    /// Ticks or unticks. Returns why it cannot be ticked, if so.
    func toggleTick(_ id: NodeID) -> String? {
        guard let session else { return nil }
        if session.ticked.contains(id) {
            session.ticked.remove(id)
            return nil
        }
        if case .denied(let reason) = verdict(id, in: session) { return reason }
        // Ticking a folder covers what was ticked inside it.
        session.ticked = session.ticked.filter { !session.store.isDescendant($0, of: id) }
        session.ticked.insert(id)
        return nil
    }

    func untickAll() {
        session?.ticked.removeAll()
    }

    var selection: (count: Int, bytes: UInt64) {
        guard let session else { return (0, 0) }
        return (session.ticked.count, session.ticked.reduce(0) { $0 + session.store.size($1) })
    }

    // MARK: Removing

    func makePlan() -> DeletionPlan? {
        guard !isSearching, let session, session.state != .volumeGone, session.state != .scanning else { return nil }
        session.verdicts.removeAll()
        return DeletionPlan.make(store: session.store, ticked: session.ticked, policy: policy, volume: session.volume, userID: env.userID)
    }

    /// Moves the plan's items to the Trash off the main thread, then updates the tree.
    func execute(_ plan: DeletionPlan, includeAdmin: Bool, completion: @escaping ([ItemOutcome]) -> Void) {
        guard let session else { return }
        let remover = env.remover(volumes: volumes, allowlist: prefs.allowlist)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcomes = remover.execute(plan, includeAdmin: includeAdmin)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for outcome in outcomes {
                        guard case .trashed(let record) = outcome.status else { continue }
                        self.lastTrashed.append(record)
                        if let id = session.store.find(outcome.path) {
                            session.store.remove(id)
                            session.ticked.remove(id)
                        }
                    }
                    session.verdicts.removeAll()
                    self.onTreeChanged?([])
                    self.onStateChanged?()
                    completion(outcomes)
                }
            }
        }
    }

    /// Deletes for good the given records, which must be among those this session trashed.
    func deleteForGood(_ records: [TrashRecord], completion: @escaping ([PermanentDeleter.Outcome]) -> Void) {
        let mine = records.filter { r in lastTrashed.contains(r) }
        let deleter = env.permanentDeleter(volumes: volumes)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcomes = deleter.delete(mine)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let done = Set(outcomes.filter { $0.error == nil }.map(\.record.trashed))
                    self.lastTrashed.removeAll { done.contains($0.trashed) }
                    completion(outcomes)
                }
            }
        }
    }

    // MARK: Suggestions

    func suggestions() -> [Suggestion] {
        guard let session = sessions.values.first(where: { $0.volume.kind == .startupData }), session.state == .finished || session.state == .cancelled else { return [] }
        return SuggestionFinder.find(in: session.store, home: env.home, now: Date())
    }

    var startupSession: ScanSession? { sessions.values.first { $0.volume.kind == .startupData } }
}
