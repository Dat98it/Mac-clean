import Foundation

/// Real disk usage of a set of paths: allocated blocks, each hard-linked file counted once, and
/// APFS clones counted by their private (unshared) size when the volume reports it.
public struct SizeCalculator: Sendable {
    public var fileSystem: FileSystem

    public init(fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }

    public struct Totals: Sendable, Equatable {
        /// What removing these paths would free.
        public var bytes: UInt64 = 0
        /// What a naive sum of allocated sizes would say (for comparison).
        public var naiveBytes: UInt64 = 0
        public var unreadableCount = 0

        public init() {}
    }

    /// `seen` carries (device, inode) pairs across calls so hard links shared by several findings
    /// are counted once overall.
    public func size(of paths: [String], seen: inout Set<[UInt64]>, isCancelled: () -> Bool = { false }) -> Totals {
        var totals = Totals()
        var stack = paths
        while let path = stack.popLast() {
            if isCancelled() { break }
            guard let info = try? fileSystem.info(path) else {
                totals.unreadableCount += 1
                continue
            }
            totals.naiveBytes += info.allocatedSize
            if seen.insert([info.device, info.inode]).inserted {
                totals.bytes += info.privateSize.map { min($0, info.allocatedSize) } ?? info.allocatedSize
            }
            // Symbolic links are sized as the link itself, never followed.
            if info.type == .directory {
                guard let children = try? fileSystem.contents(ofDirectory: path) else {
                    totals.unreadableCount += 1
                    continue
                }
                stack += children.map { Paths.join(path, $0) }
            }
        }
        return totals
    }
}
