import Foundation

public typealias NodeID = UInt32

public enum NodeKind: UInt8, Sendable {
    case directory = 1, file = 2, symlink = 3, other = 4
}

/// Facts about a node that are not sizes or dates.
public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// iCloud or File Provider placeholder: the content is not on this disk.
    public static let dataless = NodeFlags(rawValue: 1 << 0)
    public static let compressed = NodeFlags(rawValue: 1 << 1)
    /// Another name of a file already counted: its size is not counted again.
    public static let hardLinkExtra = NodeFlags(rawValue: 1 << 2)
    /// May share blocks with an APFS clone: removing it may free less than its size.
    public static let clone = NodeFlags(rawValue: 1 << 3)
    /// A folder that could not be read (permissions, SIP, or the volume went away).
    public static let unreadable = NodeFlags(rawValue: 1 << 4)
    /// .app, .bundle, .photoslibrary...: shown as one item.
    public static let package = NodeFlags(rawValue: 1 << 5)
    public static let sparse = NodeFlags(rawValue: 1 << 6)
    public static let purgeable = NodeFlags(rawValue: 1 << 7)
}

/// What the scanner hands over for one entry. Sizes are already decided: `allocated` is what this
/// entry adds to the totals (zero for a second name of a hard-linked file).
public struct NodeRecord: Sendable, Equatable {
    public var name: String
    public var kind: NodeKind
    public var flags: NodeFlags
    public var allocated: UInt64
    public var logical: UInt64
    /// Seconds since 1970; 0 when the file system does not keep it.
    public var birth: UInt32
    public var modified: UInt32

    public init(name: String, kind: NodeKind, flags: NodeFlags = [], allocated: UInt64 = 0, logical: UInt64 = 0,
                birth: UInt32 = 0, modified: UInt32 = 0) {
        self.name = name
        self.kind = kind
        self.flags = flags
        self.allocated = allocated
        self.logical = logical
        self.birth = birth
        self.modified = modified
    }
}

/// The entries of one folder, with the ids the scanner gave them (`firstID`, `firstID + 1`, ...).
public struct ScanBatch: Sendable, Equatable {
    public var parent: NodeID
    public var firstID: NodeID
    public var records: [NodeRecord]
    /// Set when the folder could not be read; `records` is then empty.
    public var parentUnreadable: Bool

    public init(parent: NodeID, firstID: NodeID, records: [NodeRecord], parentUnreadable: Bool = false) {
        self.parent = parent
        self.firstID = firstID
        self.records = records
        self.parentUnreadable = parentUnreadable
    }
}

/// The whole tree of one volume, one array per field and indices instead of objects, so two
/// million entries fit in about 150 MB. Node 0 is the volume root. Parents always come before their
/// children. Not thread-safe: owned by one thread (the main thread in the app).
public final class NodeStore {
    public let rootPath: String
    public let firmlinks: FirmlinkMap?

    private var parent: [NodeID] = []
    private var firstChild: [NodeID] = []
    private var nextSibling: [NodeID] = []
    private var nameStart: [UInt32] = []
    private var nameLength: [UInt16] = []
    private var names: [UInt8] = []
    private var allocated: [UInt64] = []
    private var logical: [UInt64] = []
    private var subtree: [UInt64] = []
    private var birth: [UInt32] = []
    private var modified: [UInt32] = []
    private var kinds: [UInt8] = []
    private var flagBits: [UInt8] = []

    /// No node: used for "no child" and "no sibling" (node 0 is the root, never anyone's child).
    static let none: NodeID = 0

    public init(rootPath: String, firmlinks: FirmlinkMap? = nil, expectedCount: Int = 0, root: NodeRecord? = nil) {
        self.rootPath = rootPath
        self.firmlinks = firmlinks
        reserve(expectedCount)
        let record = root ?? NodeRecord(name: rootPath, kind: .directory)
        appendRaw(record, parent: 0)
    }

    public var count: Int { parent.count }

    func reserve(_ n: Int) {
        guard n > 0 else { return }
        parent.reserveCapacity(n); firstChild.reserveCapacity(n); nextSibling.reserveCapacity(n)
        nameStart.reserveCapacity(n); nameLength.reserveCapacity(n); names.reserveCapacity(n * 20)
        allocated.reserveCapacity(n); logical.reserveCapacity(n); subtree.reserveCapacity(n)
        birth.reserveCapacity(n); modified.reserveCapacity(n); kinds.reserveCapacity(n); flagBits.reserveCapacity(n)
    }

    @discardableResult
    private func appendRaw(_ r: NodeRecord, parent p: NodeID) -> NodeID {
        let id = NodeID(parent.count)
        parent.append(p)
        firstChild.append(Self.none)
        nextSibling.append(Self.none)
        let bytes = Array(r.name.utf8.prefix(Int(UInt16.max)))
        nameStart.append(UInt32(names.count))
        nameLength.append(UInt16(bytes.count))
        names.append(contentsOf: bytes)
        allocated.append(r.allocated)
        logical.append(r.logical)
        subtree.append(r.allocated)
        birth.append(r.birth)
        modified.append(r.modified)
        kinds.append(r.kind.rawValue)
        flagBits.append(r.flags.rawValue)
        return id
    }

    /// Adds one folder's entries and adds their sizes to every ancestor. Returns false (and changes
    /// nothing) when the batch does not fit: unknown parent or ids out of order.
    @discardableResult
    public func apply(_ batch: ScanBatch) -> Bool {
        guard Int(batch.parent) < count else { return false }
        if batch.parentUnreadable {
            flagBits[Int(batch.parent)] |= NodeFlags.unreadable.rawValue
            return true
        }
        guard Int(batch.firstID) == count else { return false }
        var total: UInt64 = 0
        for record in batch.records {
            let id = appendRaw(record, parent: batch.parent)
            total += record.allocated
            // Children are linked in reverse order of arrival; order is decided when displayed.
            nextSibling[Int(id)] = firstChild[Int(batch.parent)]
            firstChild[Int(batch.parent)] = id
        }
        var node = batch.parent
        while true {
            subtree[Int(node)] += total
            if node == 0 { break }
            node = parent[Int(node)]
        }
        return true
    }

    /// Takes a node (and everything below it) out of the tree, after it went to the Trash: it is
    /// unlinked from its parent and its size is taken off every ancestor. Its id stays allocated.
    @discardableResult
    public func remove(_ id: NodeID) -> Bool {
        guard id != 0, Int(id) < count, let p = parent(of: id) else { return false }
        if firstChild[Int(p)] == id {
            firstChild[Int(p)] = nextSibling[Int(id)]
        } else {
            var child = firstChild[Int(p)]
            while child != Self.none && nextSibling[Int(child)] != id { child = nextSibling[Int(child)] }
            guard child != Self.none else { return false }
            nextSibling[Int(child)] = nextSibling[Int(id)]
        }
        nextSibling[Int(id)] = Self.none
        let bytes = subtree[Int(id)]
        var node = p
        while true {
            subtree[Int(node)] -= min(bytes, subtree[Int(node)])
            if node == 0 { break }
            node = parent[Int(node)]
        }
        removed.insert(id)
        return true
    }

    /// Nodes taken out with `remove` (their descendants are unreachable too).
    public private(set) var removed = Set<NodeID>()

    /// False for a removed node or anything below one.
    public func isInTree(_ id: NodeID) -> Bool {
        var node = id
        while node != 0 {
            if removed.contains(node) { return false }
            node = parent[Int(node)]
        }
        return true
    }

    // MARK: Reading

    public func name(_ id: NodeID) -> String {
        let start = Int(nameStart[Int(id)])
        return String(decoding: names[start..<start + Int(nameLength[Int(id)])], as: UTF8.self)
    }

    public func parent(of id: NodeID) -> NodeID? { id == 0 ? nil : parent[Int(id)] }
    public func kind(_ id: NodeID) -> NodeKind { NodeKind(rawValue: kinds[Int(id)]) ?? .other }
    public func flags(_ id: NodeID) -> NodeFlags { NodeFlags(rawValue: flagBits[Int(id)]) }
    /// What this entry alone occupies (hard links counted once).
    public func ownSize(_ id: NodeID) -> UInt64 { allocated[Int(id)] }
    /// What this entry and everything below it occupies.
    public func size(_ id: NodeID) -> UInt64 { subtree[Int(id)] }
    public func logicalSize(_ id: NodeID) -> UInt64 { logical[Int(id)] }
    public func birthDate(_ id: NodeID) -> Date? { birth[Int(id)] == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(birth[Int(id)])) }
    public func modifiedDate(_ id: NodeID) -> Date? { modified[Int(id)] == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(modified[Int(id)])) }
    public func modifiedSeconds(_ id: NodeID) -> UInt32 { modified[Int(id)] }
    public func birthSeconds(_ id: NodeID) -> UInt32 { birth[Int(id)] }

    /// A folder that can be opened in the outline (not a package, unless asked).
    public func isExpandable(_ id: NodeID, intoPackages: Bool = false) -> Bool {
        kind(id) == .directory && (intoPackages || !flags(id).contains(.package)) && firstChild[Int(id)] != Self.none
    }

    public func children(_ id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var child = firstChild[Int(id)]
        while child != Self.none {
            result.append(child)
            child = nextSibling[Int(child)]
        }
        return result
    }

    /// Path as scanned (for the startup disk, under /System/Volumes/Data).
    public func scanPath(_ id: NodeID) -> String {
        if id == 0 { return rootPath }
        var components: [String] = []
        var node = id
        while node != 0 {
            components.append(name(node))
            node = parent[Int(node)]
        }
        return components.reversed().reduce(rootPath) { Paths.join($0, $1) }
    }

    /// Path as the rest of the system sees it (firmlinks applied): the one checked and acted on.
    public func path(_ id: NodeID) -> String {
        let raw = scanPath(id)
        return firmlinks?.displayPath(raw) ?? raw
    }

    /// The node at a (display or scan) path, if it was scanned.
    public func find(_ path: String) -> NodeID? {
        var relative: Substring
        if path == rootPath { return 0 }
        if Paths.isInside(path, rootPath) {
            relative = path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1)
        } else if firmlinks != nil, path.hasPrefix("/") {
            // Display path of the startup disk: /Users/a is /System/Volumes/Data/Users/a.
            relative = path.dropFirst()
        } else {
            return nil
        }
        var node: NodeID = 0
        for component in relative.split(separator: "/") {
            guard let next = children(node).first(where: { name($0) == component }) else { return nil }
            node = next
        }
        return node
    }

    /// `id` is `ancestor` or below it.
    public func isDescendant(_ id: NodeID, of ancestor: NodeID) -> Bool {
        var node = id
        while true {
            if node == ancestor { return true }
            if node == 0 { return false }
            node = parent[Int(node)]
        }
    }

    /// Every node for which `match` is true, in id order, at most `limit`.
    public func search(limit: Int, isCancelled: () -> Bool = { false }, _ match: (NodeID) -> Bool) -> (ids: [NodeID], truncated: Bool) {
        var result: [NodeID] = []
        var id: NodeID = 1
        while Int(id) < count {
            if id & 0xFFFF == 0 && isCancelled() { break }
            if match(id) && (removed.isEmpty || isInTree(id)) {
                if result.count == limit { return (result, true) }
                result.append(id)
            }
            id += 1
        }
        return (result, false)
    }

    /// Approximate memory used by the arrays.
    public var memoryBytes: Int {
        (parent.capacity + firstChild.capacity + nextSibling.capacity + nameStart.capacity + birth.capacity + modified.capacity) * 4
            + nameLength.capacity * 2 + names.capacity + (allocated.capacity + logical.capacity + subtree.capacity) * 8
            + kinds.capacity + flagBits.capacity
    }
}
