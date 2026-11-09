import Foundation

/// Append-only record of everything moved to the Trash or deleted, one JSON object per line.
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
        case .trashed(let r):
            write(Entry(date: stamp, action: "trash", path: r.original, destination: r.trashed, bytes: r.bytes))
        case .receiptForgotten:
            write(Entry(date: stamp, action: "forget-receipt", path: outcome.path))
        case .failed(let error):
            write(Entry(date: stamp, action: "trash-failed", path: outcome.path, error: error))
        case .skipped(let reason):
            write(Entry(date: stamp, action: "skipped", path: outcome.path, error: reason))
        }
    }

    public func recordPermanent(_ record: TrashRecord, error: String?) {
        write(Entry(date: stamp, action: error == nil ? "delete-permanently" : "delete-failed",
                    path: record.trashed, bytes: record.bytes, error: error))
    }
}

/// Left-over groups the user asked not to be shown again, by identifier or folder name (lower case).
public struct IgnoreList: Sendable, Equatable {
    public private(set) var keys: Set<String>

    public init(keys: Set<String> = []) {
        self.keys = Set(keys.map { $0.lowercased() })
    }

    public mutating func add(_ key: String) { keys.insert(key.lowercased()) }
    public mutating func remove(_ key: String) { keys.remove(key.lowercased()) }
    public func contains(_ key: String) -> Bool { keys.contains(key.lowercased()) }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(keys.sorted())) ?? Data("[]".utf8)
    }

    public static func decode(_ data: Data?) -> IgnoreList {
        guard let data, let keys = try? JSONDecoder().decode([String].self, from: data) else { return IgnoreList() }
        return IgnoreList(keys: Set(keys))
    }
}
