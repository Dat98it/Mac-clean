import Foundation

/// One thing the user ticked, as it was when scanned.
public struct PlannedItem: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// A file or folder, with the identity it had when scanned.
        case path(String, device: UInt64, inode: UInt64, type: FileType)
        /// An installer receipt, forgotten with `pkgutil --forget` (administrator).
        case receipt(String)
    }

    public var target: Target
    public var kind: DataKind
    public var domain: Domain
    public var bytes: UInt64

    public var displayPath: String {
        switch target {
        case .path(let p, _, _, _): p
        case .receipt(let id): "pkgutil:" + id
        }
    }

    public var needsAdmin: Bool { domain == .system }
}

/// What will be removed: exactly the ticked findings, each re-checked by the safety policy.
public struct DeletionPlan: Sendable, Equatable {
    public var items: [PlannedItem]
    public var rejected: [Rejection]

    public struct Rejection: Sendable, Equatable {
        public var path: String
        public var reason: String
    }

    public var userItems: [PlannedItem] { items.filter { !$0.needsAdmin } }
    public var adminItems: [PlannedItem] { items.filter(\.needsAdmin) }
    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    /// Builds the plan by walking the *findings* and keeping those whose path is in `selected`.
    /// A selected path that is not one of the findings is never planned.
    public static func make(findings: [Finding], selected: Set<String>, sizes: [String: UInt64],
                            policy: SafetyPolicy) -> DeletionPlan {
        var plan = DeletionPlan(items: [], rejected: [])
        var seen = Set<String>()
        for finding in findings where selected.contains(finding.path) && seen.insert(finding.path).inserted {
            if finding.path.hasPrefix("pkgutil:") {
                let id = String(finding.path.dropFirst("pkgutil:".count))
                guard finding.kind == .receipt, ReceiptID.isValid(id) else {
                    plan.rejected.append(.init(path: finding.path, reason: "invalid receipt identifier"))
                    continue
                }
                plan.items.append(PlannedItem(target: .receipt(id), kind: .receipt, domain: .system, bytes: 0))
                continue
            }
            if case .denied(let reason) = policy.check(finding.path) {
                plan.rejected.append(.init(path: finding.path, reason: reason))
                continue
            }
            guard let info = try? policy.fileSystem.info(finding.path) else {
                plan.rejected.append(.init(path: finding.path, reason: "cannot read"))
                continue
            }
            // Nested findings: if a folder is planned, its children go with it and are not planned twice.
            plan.items.append(PlannedItem(target: .path(finding.path, device: info.device, inode: info.inode, type: info.type),
                                          kind: finding.kind, domain: finding.domain, bytes: sizes[finding.path] ?? 0))
        }
        let folders = plan.items.compactMap { item -> String? in
            if case .path(let p, _, _, .directory) = item.target { return p }
            return nil
        }
        plan.items.removeAll { item in folders.contains { SafetyPolicy.isInside(item.displayPath, $0) } }
        return plan
    }
}

public enum ReceiptID {
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count < 256 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}

// MARK: - Effects (the only things that change the disk, all behind protocols)

/// Moves one item to the Trash. Returns where it went.
public protocol Trashing: Sendable {
    func trash(_ path: String) throws -> String
}

/// Removes one item for good. Only ever called with paths inside a Trash folder.
public protocol PermanentRemoving: Sendable {
    func remove(_ path: String) throws
}

/// Runs the administrator part of a plan in one authorization: returns, per planned path or
/// receipt, where it went in the Trash (nil for receipts) or an error.
public protocol AdminActing: Sendable {
    func perform(_ items: [PlannedItem], trashFolder: String) -> [String: Result<String?, AdminError>]
}

public struct AdminError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Deletes, with administrator privileges and in one authorization, items in the Trash that
/// belong to someone else (root). Returns per path nil on success or an error.
public protocol AdminRemoving: Sendable {
    func removeForGood(_ paths: [String]) -> [String: Result<String?, AdminError>]
}

/// Unloads a user launch agent before its file is moved, so it stops running.
public protocol LaunchAgentUnloading: Sendable {
    func unload(plist path: String)
}

/// Asks whether apps are running. Identifiers in, identifiers of running apps out.
public protocol RunningAppChecking: Sendable {
    func running(among bundleIDs: [String]) -> [String]
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
        case receiptForgotten
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
    public var launchAgents: LaunchAgentUnloading?
    public var log: ActionLog?
    /// The user's Trash, for administrator moves.
    public var trashFolder: String

    public init(policy: SafetyPolicy, trasher: Trashing, admin: AdminActing? = nil, launchAgents: LaunchAgentUnloading? = nil,
                log: ActionLog? = nil, trashFolder: String) {
        self.policy = policy
        self.trasher = trasher
        self.admin = admin
        self.launchAgents = launchAgents
        self.log = log
        self.trashFolder = trashFolder
    }

    /// Re-checks every item, then moves it. One failure never stops the rest.
    /// `includeAdmin`: run the administrator items too (the user agreed to a password prompt).
    public func execute(_ plan: DeletionPlan, includeAdmin: Bool) -> [ItemOutcome] {
        var outcomes: [ItemOutcome] = []
        var adminReady: [PlannedItem] = []
        for item in plan.items {
            if item.needsAdmin {
                guard includeAdmin, admin != nil else {
                    outcomes.append(ItemOutcome(path: item.displayPath, status: .skipped("needs administrator")))
                    continue
                }
                if case .path = item.target, let problem = recheck(item) {
                    outcomes.append(ItemOutcome(path: item.displayPath, status: .skipped(problem)))
                    continue
                }
                adminReady.append(item)
                continue
            }
            guard case .path(let path, _, _, _) = item.target else { continue }
            if let problem = recheck(item) {
                outcomes.append(ItemOutcome(path: path, status: .skipped(problem)))
                continue
            }
            if item.kind == .launchItem { launchAgents?.unload(plist: path) }
            let outcome: ItemOutcome
            do {
                let trashed = try trasher.trash(path)
                guard case .path(_, let device, let inode, _) = item.target else { continue }
                outcome = ItemOutcome(path: path, status: .trashed(TrashRecord(original: path, trashed: trashed, device: device,
                                                                                inode: inode, bytes: item.bytes)))
            } catch {
                outcome = ItemOutcome(path: path, status: .failed("\(error)"))
            }
            log?.record(outcome)
            outcomes.append(outcome)
        }
        if !adminReady.isEmpty, let admin {
            let results = admin.perform(adminReady, trashFolder: trashFolder)
            for item in adminReady {
                let outcome: ItemOutcome
                switch results[item.displayPath] {
                case .success(let trashed)?:
                    switch item.target {
                    case .path(let path, let device, let inode, _):
                        outcome = ItemOutcome(path: path, status: .trashed(TrashRecord(original: path, trashed: trashed ?? "",
                                                                                        device: device, inode: inode, bytes: item.bytes)))
                    case .receipt:
                        outcome = ItemOutcome(path: item.displayPath, status: .receiptForgotten)
                    }
                case .failure(let error)?:
                    outcome = ItemOutcome(path: item.displayPath, status: .failed(error.message))
                case nil:
                    outcome = ItemOutcome(path: item.displayPath, status: .failed("no result"))
                }
                log?.record(outcome)
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// The item must still pass the policy and still be the same file system object as when scanned.
    func recheck(_ item: PlannedItem) -> String? {
        guard case .path(let path, let device, let inode, let type) = item.target else { return nil }
        if case .denied(let reason) = policy.check(path) { return reason }
        guard let now = try? policy.fileSystem.info(path) else { return "no longer exists" }
        guard now.device == device, now.inode == inode, now.type == type else { return "changed since the scan" }
        return nil
    }
}

// MARK: - Permanent deletion of what was just trashed

/// Deletes for good only items this session moved to the Trash, and only if they are still there,
/// unchanged. It has no way to list or empty the Trash.
public struct PermanentDeleter: Sendable {
    public var fileSystem: FileSystem
    public var remover: PermanentRemoving
    /// For items owned by someone else (an App Store app moved with a password is still root's).
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

    /// The records that will need an administrator password to delete.
    public func needingAdmin(_ records: [TrashRecord]) -> [TrashRecord] {
        records.filter { check($0) == nil && Ownership.domain(of: $0.trashed, default: .user, fileSystem: fileSystem, userID: userID) == .system }
    }

    /// Why a record must not be deleted, or nil when it may.
    func check(_ record: TrashRecord) -> String? {
        let path = record.trashed
        // Directly inside a Trash folder: never the folder itself, never deeper.
        guard trashFolders.contains((path as NSString).deletingLastPathComponent),
              !path.contains("/../"), !path.hasSuffix("/..") else { return "not in the Trash" }
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
            if Ownership.domain(of: record.trashed, default: .user, fileSystem: fileSystem, userID: userID) == .system {
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

    /// One line per item, each printing `OK<TAB>key<TAB>destination` or `ERR<TAB>key` so results
    /// can be matched back. Launch daemons are unloaded first. `stamp` keeps Trash names unique.
    public static func build(_ items: [PlannedItem], trashFolder: String, stamp: String) -> String {
        var lines = ["set -u"]
        for (index, item) in items.enumerated() {
            let key = quote(item.displayPath)
            switch item.target {
            case .receipt(let id):
                guard ReceiptID.isValid(id) else { continue }
                lines.append("if /usr/sbin/pkgutil --forget \(quote(id)) >/dev/null 2>&1; then printf 'OK\\t%s\\t\\n' \(key); else printf 'ERR\\t%s\\n' \(key); fi")
            case .path(let path, _, _, _):
                let destination = trashFolder + "/" + uniqueName((path as NSString).lastPathComponent, stamp: stamp, index: index)
                if item.kind == .launchItem && path.hasPrefix("/Library/LaunchDaemons/") {
                    lines.append("/bin/launchctl bootout system \(quote(path)) >/dev/null 2>&1 || true")
                }
                lines.append("if /bin/mv -n -- \(quote(path)) \(quote(destination)) && [ ! -e \(quote(path)) ] && [ ! -L \(quote(path)) ]; then printf 'OK\\t%s\\t%s\\n' \(key) \(quote(destination)); else printf 'ERR\\t%s\\n' \(key); fi")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `Foo.app` → `Foo 1793254843-0.app`: unique in the Trash, still recognisable as an app.
    static func uniqueName(_ name: String, stamp: String, index: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return base + " " + stamp + "-" + String(index) + (ext.isEmpty ? "" : "." + ext)
    }

    /// Deletes Trash items for good. Each path has been checked by `PermanentDeleter` (directly in a
    /// Trash folder, same file as was trashed). `rm` never follows a symbolic link given as an operand.
    public static func buildRemoval(_ paths: [String]) -> String {
        var lines = ["set -u"]
        for path in paths where !path.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            let q = quote(path)
            lines.append("if /bin/rm -rf -- \(q) && [ ! -e \(q) ] && [ ! -L \(q) ]; then printf 'OK\\t%s\\t\\n' \(q); else printf 'ERR\\t%s\\n' \(q); fi")
        }
        return lines.joined(separator: "\n")
    }

    /// Parses the script's output back into results. Items with no line are failures.
    public static func parse(_ output: String, items: [PlannedItem]) -> [String: Result<String?, AdminError>] {
        parse(output, keys: items.map(\.displayPath))
    }

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
