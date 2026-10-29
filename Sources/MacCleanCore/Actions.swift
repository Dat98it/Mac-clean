import Foundation

// Adapted from App Clean's Actions.swift: plan → re-check → act, effects behind protocols,
// permanent deletion only of what this session moved to the Trash.

/// One ticked item, as it was when the plan was made.
public struct PlannedItem: Sendable, Equatable {
    public var path: String
    public var device: UInt64
    public var inode: UInt64
    public var type: FileType
    /// For files on volumes without stable ids (FAT, exFAT): the item must also keep its size and date.
    public var size: UInt64
    public var modified: Date
    public var checkSizeAndDate: Bool
    /// What the scan says it occupies.
    public var bytes: UInt64
    public var ownership: Ownership

    public var needsAdmin: Bool { ownership == .administrator }
}

/// What will be moved: exactly the ticked nodes, each checked by the safety policy.
public struct DeletionPlan: Sendable, Equatable {
    public var items: [PlannedItem]
    public var rejected: [Rejection]

    public struct Rejection: Sendable, Equatable {
        public var path: String
        public var reason: String
    }

    public var userItems: [PlannedItem] { items.filter { !$0.needsAdmin } }
    public var adminItems: [PlannedItem] { items.filter { $0.needsAdmin } }
    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    /// Builds the plan from the ticked node ids only. A ticked node inside another ticked folder goes
    /// with its folder and is not planned twice.
    public static func make(store: NodeStore, ticked: Set<NodeID>, policy: SafetyPolicy, volume: Volume, userID: UInt32?) -> DeletionPlan {
        var plan = DeletionPlan(items: [], rejected: [])
        for id in ticked.sorted() {
            guard Int(id) < store.count, id != 0 else { continue }
            // Goes with a ticked folder above it.
            if store.parent(of: id).flatMap({ firstTicked(from: $0, in: ticked, store: store) }) != nil { continue }
            let path = store.path(id)
            if case .denied(let reason) = policy.check(path) {
                plan.rejected.append(.init(path: path, reason: reason))
                continue
            }
            guard let info = try? policy.fileSystem.info(path) else {
                plan.rejected.append(.init(path: path, reason: "cannot read"))
                continue
            }
            guard matches(store.kind(id), info.type) else {
                plan.rejected.append(.init(path: path, reason: "changed since the scan"))
                continue
            }
            plan.items.append(PlannedItem(path: path, device: info.device, inode: info.inode, type: info.type, size: info.size,
                                          modified: info.modified, checkSizeAndDate: !volume.hasStableIdentity && info.type == .regular,
                                          bytes: store.size(id),
                                          ownership: Ownership.of(path, fileSystem: policy.fileSystem, userID: userID)))
        }
        return plan
    }

    /// The closest ticked node at or above `id`.
    static func firstTicked(from id: NodeID, in ticked: Set<NodeID>, store: NodeStore) -> NodeID? {
        var node: NodeID? = id
        while let n = node {
            if ticked.contains(n) { return n }
            node = store.parent(of: n)
        }
        return nil
    }

    static func matches(_ kind: NodeKind, _ type: FileType) -> Bool {
        switch (kind, type) {
        case (.directory, .directory), (.file, .regular), (.symlink, .symlink), (.other, .other): true
        default: false
        }
    }
}

// MARK: - Effects (the only things that change the disk, all behind protocols)

/// Moves one item to the Trash (the one on its own volume). Returns where it went.
public protocol Trashing: Sendable {
    func trash(_ path: String) throws -> String
}

/// Removes one item for good. Only ever called with paths directly inside a Trash folder.
public protocol PermanentRemoving: Sendable {
    func remove(_ path: String) throws
}

/// Runs the administrator part of a plan in one authorization: returns, per planned path, where
/// it went in the Trash or an error.
public protocol AdminActing: Sendable {
    func perform(_ items: [PlannedItem], trashFolder: String) -> [String: Result<String?, AdminError>]
}

/// Deletes for good, with administrator privileges, Trash items that belong to someone else.
public protocol AdminRemoving: Sendable {
    func removeForGood(_ paths: [String]) -> [String: Result<String?, AdminError>]
}

/// Which of these paths (or anything inside them) some process has open, with that process's name.
public protocol OpenFileChecking: Sendable {
    func openItems(under paths: [String]) -> [String: String]
}

/// Mount points mounted right now.
public protocol MountChecking: Sendable {
    func mountedVolumes() -> Set<String>
}

public struct AdminError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

// MARK: - Executing a plan

public struct TrashRecord: Sendable, Equatable, Codable {
    public var original: String
    public var trashed: String
    public var device: UInt64
    public var inode: UInt64
    public var bytes: UInt64
}

public struct ItemOutcome: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case trashed(TrashRecord)
        case skipped(String)
        case failed(String)
    }
    public var path: String
    public var status: Status
}

public struct Remover: Sendable {
    public var policy: SafetyPolicy
    public var trasher: Trashing
    public var admin: AdminActing?
    public var openFiles: OpenFileChecking
    public var mounts: MountChecking
    public var log: ActionLog?
    /// Where administrator moves put items on a volume (by mount point): ~/.Trash on the startup
    /// disk, /Volumes/X/.Trashes/<uid> elsewhere. Never across volumes (that would copy).
    public var trashFolder: @Sendable (String) -> String

    public init(policy: SafetyPolicy, trasher: Trashing, admin: AdminActing? = nil, openFiles: OpenFileChecking,
                mounts: MountChecking, log: ActionLog? = nil, trashFolder: @escaping @Sendable (String) -> String) {
        self.policy = policy
        self.trasher = trasher
        self.admin = admin
        self.openFiles = openFiles
        self.mounts = mounts
        self.log = log
        self.trashFolder = trashFolder
    }

    /// Re-checks every item, then moves it. One failure never stops the rest.
    /// `includeAdmin`: run the administrator items too (the user agreed to a password prompt).
    public func execute(_ plan: DeletionPlan, includeAdmin: Bool) -> [ItemOutcome] {
        var outcomes: [ItemOutcome] = []
        var adminReady: [PlannedItem] = []
        let inUse = openFiles.openItems(under: plan.items.map(\.path))
        let mounted = mounts.mountedVolumes()
        for item in plan.items {
            if let problem = recheck(item, inUse: inUse, mounted: mounted) {
                let outcome = ItemOutcome(path: item.path, status: .skipped(problem))
                log?.record(outcome)
                outcomes.append(outcome)
                continue
            }
            if item.needsAdmin {
                guard includeAdmin, admin != nil else {
                    outcomes.append(ItemOutcome(path: item.path, status: .skipped("needs administrator")))
                    continue
                }
                adminReady.append(item)
                continue
            }
            let outcome: ItemOutcome
            do {
                let trashed = try trasher.trash(item.path)
                outcome = ItemOutcome(path: item.path, status: .trashed(TrashRecord(original: item.path, trashed: trashed, device: item.device,
                                                                                     inode: item.inode, bytes: item.bytes)))
            } catch {
                outcome = ItemOutcome(path: item.path, status: .failed("\(error)"))
            }
            log?.record(outcome)
            outcomes.append(outcome)
        }
        if !adminReady.isEmpty, let admin {
            var results: [String: Result<String?, AdminError>] = [:]
            let byVolume = Dictionary(grouping: adminReady) { VolumeCatalogRules.volume(containing: $0.path, in: policy.volumes)?.mountPoint ?? "" }
            for (mountPoint, items) in byVolume.sorted(by: { $0.key < $1.key }) where !mountPoint.isEmpty {
                results.merge(admin.perform(items, trashFolder: trashFolder(mountPoint))) { a, _ in a }
            }
            for item in adminReady {
                let outcome: ItemOutcome
                switch results[item.path] {
                case .success(let trashed)?:
                    outcome = ItemOutcome(path: item.path, status: .trashed(TrashRecord(original: item.path, trashed: trashed ?? "",
                                                                                         device: item.device, inode: item.inode, bytes: item.bytes)))
                case .failure(let error)?:
                    outcome = ItemOutcome(path: item.path, status: .failed(error.message))
                case nil:
                    outcome = ItemOutcome(path: item.path, status: .failed("no result"))
                }
                log?.record(outcome)
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// The item must still pass the policy, its volume must still be mounted, nothing may have it
    /// open, and it must still be the same file system object as when planned.
    func recheck(_ item: PlannedItem, inUse: [String: String], mounted: Set<String>) -> String? {
        guard let volume = VolumeCatalogRules.volume(containing: item.path, in: policy.volumes),
              mounted.contains(volume.mountPoint) else { return "the volume is no longer connected" }
        if case .denied(let reason) = policy.check(item.path) { return reason }
        if let process = inUse[item.path] { return "in use by \(process)" }
        guard let now = try? policy.fileSystem.info(item.path) else { return "no longer exists" }
        guard now.device == item.device, now.inode == item.inode, now.type == item.type else { return "changed since the scan" }
        if item.checkSizeAndDate, now.size != item.size || now.modified != item.modified { return "changed since the scan" }
        return nil
    }
}

// MARK: - Permanent deletion of what was just trashed

/// Deletes for good only items this session moved to the Trash, and only if they are still there,
/// unchanged. It has no way to list or empty the Trash.
public struct PermanentDeleter: Sendable {
    public var fileSystem: FileSystem
    public var remover: PermanentRemoving
    public var admin: AdminRemoving?
    public var userID: UInt32?
    /// Trash folders items may be in: ~/.Trash and /Volumes/*/.Trashes/<uid>.
    public var trashFolders: [String]
    public var log: ActionLog?

    public init(fileSystem: FileSystem, remover: PermanentRemoving, admin: AdminRemoving? = nil, userID: UInt32? = nil,
                trashFolders: [String], log: ActionLog? = nil) {
        self.fileSystem = fileSystem
        self.remover = remover
        self.admin = admin
        self.userID = userID
        self.trashFolders = trashFolders
        self.log = log
    }

    public struct Outcome: Sendable, Equatable {
        public var record: TrashRecord
        public var error: String?
    }

    /// Why a record must not be deleted, or nil when it may.
    func check(_ record: TrashRecord) -> String? {
        let path = record.trashed
        // Directly inside a Trash folder: never the folder itself, never deeper.
        guard trashFolders.contains(Paths.parent(path)), !path.contains("/../"), !path.hasSuffix("/..") else { return "not in the Trash" }
        guard let info = try? fileSystem.info(path) else { return "no longer in the Trash" }
        guard info.inode == record.inode, info.device == record.device else { return "the item in the Trash has changed" }
        return nil
    }

    public func delete(_ records: [TrashRecord]) -> [Outcome] {
        var outcomes: [String: Outcome] = [:]
        var forAdmin: [TrashRecord] = []
        for record in records {
            if let problem = check(record) {
                outcomes[record.trashed] = Outcome(record: record, error: problem)
                continue
            }
            if Ownership.of(record.trashed, fileSystem: fileSystem, userID: userID) == .administrator {
                forAdmin.append(record)
                continue
            }
            do {
                try remover.remove(record.trashed)
                log?.recordPermanent(record, error: nil)
                outcomes[record.trashed] = Outcome(record: record, error: nil)
            } catch {
                log?.recordPermanent(record, error: "\(error)")
                outcomes[record.trashed] = Outcome(record: record, error: "\(error)")
            }
        }
        if !forAdmin.isEmpty {
            let results = admin?.removeForGood(forAdmin.map(\.trashed)) ?? [:]
            for record in forAdmin {
                let error: String?
                switch results[record.trashed] {
                case .success?: error = nil
                case .failure(let e)?: error = e.message
                case nil: error = admin == nil ? "needs administrator" : "not done"
                }
                log?.recordPermanent(record, error: error)
                outcomes[record.trashed] = Outcome(record: record, error: error)
            }
        }
        return records.compactMap { outcomes[$0.trashed] }
    }
}

// MARK: - Administrator script

/// Builds the shell script run with administrator privileges. Every path is single-quoted, and the
/// policy has already rejected control characters, so nothing in a path can become shell syntax.
public enum AdminScript {
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One line per item, each printing `OK<TAB>key<TAB>destination` or `ERR<TAB>key`.
    /// `stamp` keeps Trash names unique.
    public static func build(_ items: [PlannedItem], trashFolder: String, stamp: String) -> String {
        var lines = ["set -u"]
        for (index, item) in items.enumerated() where !item.path.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            let key = quote(item.path)
            let destination = trashFolder + "/" + uniqueName(Paths.lastComponent(item.path), stamp: stamp, index: index)
            lines.append("if /bin/mv -n -- \(key) \(quote(destination)) && [ ! -e \(key) ] && [ ! -L \(key) ]; then printf 'OK\\t%s\\t%s\\n' \(key) \(quote(destination)); else printf 'ERR\\t%s\\n' \(key); fi")
        }
        return lines.joined(separator: "\n")
    }

    /// `Foo.app` → `Foo 1793254843-0.app`: unique in the Trash, still recognisable.
    static func uniqueName(_ name: String, stamp: String, index: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return base + " " + stamp + "-" + String(index) + (ext.isEmpty ? "" : "." + ext)
    }

    /// Deletes Trash items for good. Each path has been checked by `PermanentDeleter`.
    /// `rm` never follows a symbolic link given as an operand.
    public static func buildRemoval(_ paths: [String]) -> String {
        var lines = ["set -u"]
        for path in paths where !path.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            let q = quote(path)
            lines.append("if /bin/rm -rf -- \(q) && [ ! -e \(q) ] && [ ! -L \(q) ]; then printf 'OK\\t%s\\t\\n' \(q); else printf 'ERR\\t%s\\n' \(q); fi")
        }
        return lines.joined(separator: "\n")
    }

    /// Parses the script's output back into results. Keys with no line are failures.
    public static func parse(_ output: String, keys: [String]) -> [String: Result<String?, AdminError>] {
        var results: [String: Result<String?, AdminError>] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            if parts[0] == "OK" {
                let destination = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
                results[parts[1]] = .success(destination)
            } else if parts[0] == "ERR" {
                results[parts[1]] = .failure(AdminError("failed"))
            }
        }
        for key in keys where results[key] == nil {
            results[key] = .failure(AdminError("not done"))
        }
        return results
    }
}

// MARK: - Action log

/// Append-only record of everything moved to the Trash, skipped, or deleted: one JSON object per line.
public struct ActionLog: Sendable {
    public var append: @Sendable (String) -> Void
    public var now: @Sendable () -> Date

    public init(append: @escaping @Sendable (String) -> Void, now: @escaping @Sendable () -> Date = { Date() }) {
        self.append = append
        self.now = now
    }

    struct Entry: Codable {
        var date: String
        var action: String
        var path: String
        var destination: String?
        var bytes: UInt64?
        var error: String?
    }

    func write(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(entry) { append(String(decoding: data, as: UTF8.self)) }
    }

    var stamp: String { ISO8601DateFormatter().string(from: now()) }

    public func record(_ outcome: ItemOutcome) {
        switch outcome.status {
        case .trashed(let r): write(Entry(date: stamp, action: "trash", path: r.original, destination: r.trashed, bytes: r.bytes))
        case .failed(let error): write(Entry(date: stamp, action: "trash-failed", path: outcome.path, error: error))
        case .skipped(let reason): write(Entry(date: stamp, action: "skipped", path: outcome.path, error: reason))
        }
    }

    public func recordPermanent(_ record: TrashRecord, error: String?) {
        write(Entry(date: stamp, action: error == nil ? "delete" : "delete-failed", path: record.trashed, bytes: record.bytes, error: error))
    }
}
