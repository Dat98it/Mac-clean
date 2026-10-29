import Foundation

public enum SortColumn: String, Sendable, CaseIterable {
    case name, size, created, modified, kind
}

public struct SortOrder: Sendable, Equatable {
    public var column: SortColumn
    public var ascending: Bool

    public init(column: SortColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    /// Largest first: what someone looking for space wants.
    public static let `default` = SortOrder(column: .size, ascending: false)
}

public struct BrowseFilter: Sendable, Equatable {
    /// Part of the name, case and accent insensitive. Empty: no name filter.
    public var name: String
    /// Hide items (folders by their total) smaller than this.
    public var minimumSize: UInt64
    /// Only items not modified for at least this many days.
    public var minimumAgeDays: Int?

    public init(name: String = "", minimumSize: UInt64 = 0, minimumAgeDays: Int? = nil) {
        self.name = name
        self.minimumSize = minimumSize
        self.minimumAgeDays = minimumAgeDays
    }

    /// Name and age filters show a flat list of matches across the volume instead of the tree.
    public var isFlat: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty || minimumAgeDays != nil }
}

public enum Browse {
    /// Children of a node in display order, without those the size filter hides.
    public static func children(of id: NodeID, in store: NodeStore, order: SortOrder, filter: BrowseFilter) -> [NodeID] {
        let ids = store.children(id).filter { store.size($0) >= filter.minimumSize }
        return sort(ids, in: store, order: order)
    }

    public static func sort(_ ids: [NodeID], in store: NodeStore, order: SortOrder) -> [NodeID] {
        // Names are decoded once, not on every comparison.
        let names = order.column == .name || order.column == .kind ? Dictionary(uniqueKeysWithValues: ids.map { ($0, store.name($0)) }) : [:]
        func ascending(_ a: NodeID, _ b: NodeID) -> Bool {
            switch order.column {
            case .name:
                return names[a]!.localizedStandardCompare(names[b]!) == .orderedAscending
            case .size:
                let (x, y) = (store.size(a), store.size(b))
                return x != y ? x < y : a < b
            case .created:
                let (x, y) = (store.birthSeconds(a), store.birthSeconds(b))
                return x != y ? x < y : a < b
            case .modified:
                let (x, y) = (store.modifiedSeconds(a), store.modifiedSeconds(b))
                return x != y ? x < y : a < b
            case .kind:
                let (x, y) = (kindKey(a, store: store, name: names[a]!), kindKey(b, store: store, name: names[b]!))
                if x != y { return x.localizedStandardCompare(y) == .orderedAscending }
                return names[a]!.localizedStandardCompare(names[b]!) == .orderedAscending
            }
        }
        return ids.sorted { order.ascending ? ascending($0, $1) : ascending($1, $0) }
    }

    /// Folders first, then by extension.
    static func kindKey(_ id: NodeID, store: NodeStore, name: String) -> String {
        switch store.kind(id) {
        case .directory: return store.flags(id).contains(.package) ? "1 " + (name as NSString).pathExtension.lowercased() : "0"
        case .symlink: return "3"
        case .other: return "4"
        case .file: return "2 " + (name as NSString).pathExtension.lowercased()
        }
    }

    /// Every node matching the filter, largest first by default, at most `limit`.
    public static func matches(in store: NodeStore, filter: BrowseFilter, order: SortOrder, now: Date, limit: Int = 5000,
                               isCancelled: () -> Bool = { false }) -> (ids: [NodeID], truncated: Bool) {
        let needle = filter.name.trimmingCharacters(in: .whitespaces)
        let cutoff: UInt32? = filter.minimumAgeDays.map { UInt32(max(0, now.timeIntervalSince1970 - Double($0) * 86_400)) }
        // Collect all matches (ids only), then keep the first `limit` in display order.
        let (ids, _) = store.search(limit: Int.max, isCancelled: isCancelled) { id in
            if store.size(id) < filter.minimumSize { return false }
            if let cutoff {
                let modified = store.modifiedSeconds(id)
                if modified == 0 || modified > cutoff { return false }
            }
            if !needle.isEmpty {
                return store.name(id).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            return true
        }
        let sorted = sort(ids, in: store, order: order)
        return (Array(sorted.prefix(limit)), sorted.count > limit)
    }
}
