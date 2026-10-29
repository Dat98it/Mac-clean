import Foundation

/// The last word on whether a path may be moved to the Trash. Checked when an item is ticked, when
/// the plan is made, and again right before acting. A pure function of the path, the configuration
/// and what `lstat`/`realpath` say.
///
/// Adapted from App Clean's SafetyPolicy (protected paths and trees, no symbolic link on the way,
/// nothing containing a protected folder), with zones and volume rules for arbitrary files.
public struct SafetyPolicy: Sendable {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)

        public var isAllowed: Bool { self == .allowed }
    }

    public var fileSystem: FileSystem
    public var home: String
    /// Mounted volumes, as last read. A path on no known volume, or on one that cannot be
    /// changed (read-only, NTFS, Time Machine), is never allowed.
    public var volumes: [Volume]
    /// Extra folders the user allowed in Settings (each validated with `canAllowlist`).
    public var allowlist: [String]
    /// This app's own bundle: never removed.
    public var selfBundlePath: String?
    /// More trees to protect. Empty in the app; tests use it to prove that the "contains a protected
    /// folder" layer works on its own (in the default setup other layers cover the same paths).
    var extraProtectedTrees: [String] = []

    public init(fileSystem: FileSystem, home: String, volumes: [Volume], allowlist: [String] = [], selfBundlePath: String? = nil) {
        self.fileSystem = fileSystem
        self.home = home
        self.volumes = volumes
        self.allowlist = allowlist
        self.selfBundlePath = selfBundlePath
    }

    /// Never removed, and nothing that contains them is removed either.
    public var protectedPaths: [String] {
        let system = ["/", "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/private/var", "/private/etc",
                      "/private/tmp", "/tmp", "/opt", "/cores", "/dev", "/Library", "/Applications", "/Users", "/Volumes",
                      "/Network", "/System/Volumes/Data", "/Library/Caches", "/Library/Application Support"]
        let user = ["", "/Desktop", "/Documents", "/Downloads", "/Movies", "/Music", "/Pictures", "/Public", "/Applications",
                    "/Library", "/Library/Caches", "/Library/Application Support", "/Library/Preferences", "/Library/Containers",
                    "/Library/Group Containers", "/Library/Developer", "/Library/Logs"].map { home + $0 }
        let volumeRoots = volumes.map(\.mountPoint)
        return system + user + volumeRoots
    }

    /// Whole subtrees that are never touched.
    public var protectedTrees: [String] {
        ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/var/db", "/private/var/vm", "/Library/Apple", "/Library/Keychains",
         "/Library/Security", "/System/Volumes/Data/System",
         home + "/Library/Keychains", home + "/Library/Mail", home + "/Library/Messages", home + "/Library/Mobile Documents",
         home + "/Library/CloudStorage", home + "/Library/Accounts", home + "/Library/Cookies", home + "/Library/Safari",
         home + "/Library/Calendars", home + "/Library/Application Support/AddressBook",
         home + "/Library/Containers/com.apple.mail", home + "/Library/Group Containers/group.com.apple.notes",
         home + "/.Trash"] + extraProtectedTrees
    }

    public func check(_ path: String) -> Verdict {
        // 1. Shape: absolute, normalized, printable.
        if let problem = Self.shapeProblem(path) { return .denied(problem) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()

        // 2. Protected places, and anything containing one.
        if protectedPaths.contains(path) { return .denied("protected folder") }
        if let tree = protectedTrees.first(where: { Paths.isWithin(path, $0) }) { return .denied("inside protected folder \(tree)") }
        if let inner = (protectedPaths + protectedTrees).first(where: { Paths.isInside($0, path) }) {
            return .denied("contains protected folder \(inner)")
        }

        // 3. Trash folders, libraries of Apple apps, and volume bookkeeping are never touched.
        if components.contains(where: { $0 == ".Trashes" || $0 == ".Trash" }) { return .denied("Trash folder") }
        if components.contains(where: { $0.hasSuffix(".photoslibrary") || $0.hasSuffix(".photolibrary") }) {
            return .denied("Photos library")
        }

        // 4. No symbolic link on the way: the parent must already be its own canonical path.
        let parent = Paths.parent(path)
        guard let canonicalParent = try? fileSystem.canonicalPath(parent) else { return .denied("cannot resolve parent folder") }
        guard canonicalParent == parent else { return .denied("path goes through a symbolic link (\(canonicalParent))") }
        guard (try? fileSystem.info(path)) != nil else { return .denied("does not exist") }

        // 5. The volume must be known and changeable.
        guard let volume = VolumeCatalogRules.volume(containing: path, in: volumes) else { return .denied("not on a known volume") }
        if volume.kind == .timeMachine { return .denied("Time Machine backup: view only") }
        if !volume.canTrash { return .denied("volume is read-only") }
        if volume.kind == .external, let first = path.dropFirst(volume.mountPoint.count + 1).split(separator: "/").first,
           ScanRules.systemFolderNames.contains(String(first)) {
            return .denied("volume bookkeeping folder")
        }

        // 6. This app.
        if let selfBundlePath, Paths.isWithin(path, selfBundlePath) || Paths.isInside(selfBundlePath, path) {
            return .denied("Mac Clean itself")
        }

        // 7. Inside an allowed zone: the home folder, an external volume, or an allowlisted folder.
        if Paths.isInside(path, home) { return .allowed }
        if volume.kind == .external && Paths.isInside(path, volume.mountPoint) { return .allowed }
        if allowlist.contains(where: { Paths.isInside(path, $0) }) { return .allowed }
        return .denied("outside the folders Mac Clean may clean")
    }

    /// Why a path is not an absolute, normalized, printable path, or nil when it is. Later layers
    /// (realpath, existence) would also stop most such paths; this one does not rely on them.
    public static func shapeProblem(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/") else { return "not an absolute path" }
        guard !path.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return "control characters in path" }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return "path is not normalized" }
        return nil
    }

    /// Whether a folder may be added to the allowlist (its contents become removable, each still
    /// checked by `check`): not a top-level system or home folder, not inside or containing a
    /// protected tree, and no symbolic link on the way.
    public func canAllowlist(_ folder: String) -> Verdict {
        guard folder.hasPrefix("/"), folder.count > 1, !folder.hasSuffix("/") else { return .denied("not an absolute path") }
        let tooBroad = ["/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/private/var", "/private/etc", "/Library",
                        "/Applications", "/Users", "/Volumes", "/Network", "/System/Volumes/Data", "/opt", "/dev", home, home + "/Library"]
        if tooBroad.contains(folder) || volumes.contains(where: { $0.mountPoint == folder }) { return .denied("folder is too broad") }
        if let tree = protectedTrees.first(where: { Paths.isWithin(folder, $0) }) { return .denied("inside protected folder \(tree)") }
        if let inner = protectedTrees.first(where: { Paths.isInside($0, folder) }) { return .denied("contains protected folder \(inner)") }
        guard let canonical = try? fileSystem.canonicalPath(folder), canonical == folder else {
            return .denied("path goes through a symbolic link")
        }
        return .allowed
    }
}
