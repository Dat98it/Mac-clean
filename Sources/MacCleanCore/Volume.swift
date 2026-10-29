import Foundation

/// A mounted file system as `getfsstat` describes it, plus the few facts read from its root.
public struct MountRecord: Sendable, Equatable {
    public var mountPoint: String
    public var device: String
    public var fileSystemType: String
    public var isLocal: Bool
    public var isReadOnly: Bool
    public var isBrowsable: Bool
    public var isRootFileSystem: Bool
    /// Bytes this volume uses (`ATTR_VOL_SPACEUSED`, as `df` shows on APFS).
    public var usedBytes: UInt64
    public var availableBytes: UInt64
    public var totalBytes: UInt64
    /// Inodes in use: a good estimate of how many entries a scan will find.
    public var filesInUse: UInt64
    /// Time Machine keeps `Backups.backupdb` or `.timemachine` at the root of its destinations.
    public var hasTimeMachineMarkers: Bool

    public init(mountPoint: String, device: String = "", fileSystemType: String, isLocal: Bool = true, isReadOnly: Bool = false,
                isBrowsable: Bool = true, isRootFileSystem: Bool = false, usedBytes: UInt64 = 0, availableBytes: UInt64 = 0,
                totalBytes: UInt64 = 0, filesInUse: UInt64 = 0, hasTimeMachineMarkers: Bool = false) {
        self.mountPoint = mountPoint
        self.device = device
        self.fileSystemType = fileSystemType
        self.isLocal = isLocal
        self.isReadOnly = isReadOnly
        self.isBrowsable = isBrowsable
        self.isRootFileSystem = isRootFileSystem
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.filesInUse = filesInUse
        self.hasTimeMachineMarkers = hasTimeMachineMarkers
    }
}

/// One volume as Mac Clean shows it: its own root, never crossing into another volume.
public struct Volume: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// The startup disk's Data volume, scanned from /System/Volumes/Data, shown with firmlink paths.
        case startupData
        /// An external or secondary local volume.
        case external
        /// A Time Machine destination: browsed, never changed.
        case timeMachine
    }

    public var id: String { mountPoint }
    public var name: String
    public var mountPoint: String
    /// Where scanning starts. Differs from `mountPoint` only for the startup disk.
    public var scanRoot: String
    public var kind: Kind
    public var fileSystemType: String
    public var isReadOnly: Bool
    public var usedBytes: UInt64
    public var availableBytes: UInt64
    public var totalBytes: UInt64
    public var filesInUse: UInt64
    /// Space a file scan cannot see but that belongs to this disk: for the startup disk, the sealed
    /// system volume, VM swap, Preboot and Recovery (separate volumes in the same container).
    public var otherParts: [Part]

    public struct Part: Sendable, Equatable {
        public var name: String
        public var bytes: UInt64
        public init(name: String, bytes: UInt64) { self.name = name; self.bytes = bytes }
    }

    public init(name: String, mountPoint: String, scanRoot: String, kind: Kind, fileSystemType: String, isReadOnly: Bool,
                usedBytes: UInt64 = 0, availableBytes: UInt64 = 0, totalBytes: UInt64 = 0, filesInUse: UInt64 = 0,
                otherParts: [Part] = []) {
        self.name = name
        self.mountPoint = mountPoint
        self.scanRoot = scanRoot
        self.kind = kind
        self.fileSystemType = fileSystemType
        self.isReadOnly = isReadOnly
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.filesInUse = filesInUse
        self.otherParts = otherParts
    }

    static let ntfsTypes: Set<String> = ["ntfs", "ufsd_NTFS", "tuxera_ntfs"]
    static let fatTypes: Set<String> = ["msdos", "exfat"]

    /// Items on it may be moved to the Trash: writable, not NTFS, not a backup.
    public var canTrash: Bool {
        !isReadOnly && kind != .timeMachine && !Self.ntfsTypes.contains(fileSystemType)
    }

    /// FAT and exFAT have no hard links, no stable file ids across mounts and no reliable creation date.
    public var hasStableIdentity: Bool { !Self.fatTypes.contains(fileSystemType) }
    public var hasBirthTime: Bool { !Self.fatTypes.contains(fileSystemType) }
    public var hasHardLinks: Bool { !Self.fatTypes.contains(fileSystemType) }

    /// Shown in menus and logs.
    public var kindDescription: String {
        switch kind {
        case .startupData: "startup"
        case .timeMachine: "time machine"
        case .external: canTrash ? "external" : "read-only"
        }
    }
}

public enum VolumeCatalogRules {
    /// Never scanned: they are remote, and reading them is slow, may prompt for passwords and may
    /// wake servers.
    public static let networkTypes: Set<String> = ["smbfs", "afpfs", "nfs", "webdav", "cifs", "ftp", "macfuse", "osxfuse", "fuse", "autofs"]
    public static let startupDataMount = "/System/Volumes/Data"

    /// Turns mount records into the volumes Mac Clean offers. Network shares, pseudo file systems,
    /// the sealed system volume and the startup disk's helper volumes are left out.
    public static func volumes(from mounts: [MountRecord]) -> [Volume] {
        var result: [Volume] = []
        for m in mounts {
            if !m.isLocal || networkTypes.contains(m.fileSystemType) || m.fileSystemType == "devfs" { continue }
            if m.mountPoint == startupDataMount {
                let helpers: [(String, String)] = [("/", "macOS system (sealed)"), ("/System/Volumes/VM", "VM swap"),
                                                   ("/System/Volumes/Preboot", "Preboot"), ("/Volumes/Recovery", "Recovery"),
                                                   ("/System/Volumes/Update", "Update")]
                let parts = helpers.compactMap { mount, name in
                    mounts.first { $0.mountPoint == mount }.map { Volume.Part(name: name, bytes: $0.usedBytes) }
                }
                result.append(Volume(name: "Macintosh HD", mountPoint: "/", scanRoot: startupDataMount, kind: .startupData,
                                     fileSystemType: m.fileSystemType, isReadOnly: m.isReadOnly,
                                     usedBytes: m.usedBytes, availableBytes: m.availableBytes,
                                     totalBytes: m.totalBytes, filesInUse: m.filesInUse, otherParts: parts))
                continue
            }
            // The sealed system volume, Preboot, VM, Recovery and friends.
            if m.mountPoint == "/" || m.mountPoint.hasPrefix("/System/Volumes/") || m.mountPoint == "/Volumes/Recovery" || !m.isBrowsable { continue }
            guard m.mountPoint.hasPrefix("/Volumes/") else { continue }
            let kind: Volume.Kind = m.hasTimeMachineMarkers ? .timeMachine : .external
            result.append(Volume(name: Paths.lastComponent(m.mountPoint), mountPoint: m.mountPoint, scanRoot: m.mountPoint, kind: kind,
                                 fileSystemType: m.fileSystemType, isReadOnly: m.isReadOnly, usedBytes: m.usedBytes,
                                 availableBytes: m.availableBytes, totalBytes: m.totalBytes, filesInUse: m.filesInUse))
        }
        return result.sorted { ($0.kind == .startupData ? 0 : 1, $0.name) < ($1.kind == .startupData ? 0 : 1, $1.name) }
    }

    /// The volume a (display) path lives on: the longest mount point that contains it.
    /// Anything under /Volumes belongs to the disk mounted there, never to the startup disk: a path
    /// on a disk that was unplugged is on no known volume.
    public static func volume(containing path: String, in volumes: [Volume]) -> Volume? {
        volumes.filter { Paths.isWithin(path, $0.mountPoint) && !($0.kind == .startupData && Paths.isInside(path, "/Volumes")) }
            .max { $0.mountPoint.count < $1.mountPoint.count }
    }
}

/// The startup disk's Data volume appears at / through firmlinks (/Users, /Applications, ...).
/// Scanning starts at /System/Volumes/Data; paths are shown and checked in their firmlink form,
/// which is what `realpath` and every other app uses.
public struct FirmlinkMap: Sendable, Equatable {
    /// Paths relative to the Data volume root that appear at the same place under /.
    public var linked: [String]

    public init(linked: [String]) {
        self.linked = linked
    }

    /// The contents of /usr/share/firmlinks: "<path on />\t<path relative to Data>".
    public static func parse(_ text: String) -> FirmlinkMap {
        var linked: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, "/" + parts[1] == String(parts[0]) else { continue }
            linked.append(String(parts[1]))
        }
        return FirmlinkMap(linked: linked)
    }

    /// `/System/Volumes/Data/Users/a` becomes `/Users/a`. Paths not under a firmlink stay as they are.
    public func displayPath(_ dataPath: String) -> String {
        let root = VolumeCatalogRules.startupDataMount
        guard Paths.isInside(dataPath, root) else { return dataPath }
        let relative = String(dataPath.dropFirst(root.count + 1))
        for link in linked where relative == link || relative.hasPrefix(link + "/") {
            return "/" + relative
        }
        return dataPath
    }
}
