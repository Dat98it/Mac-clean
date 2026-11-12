import Foundation

/// The last word on whether a path may be moved to the Trash or deleted. Checked when a plan is
/// made and again, item by item, right before acting. A pure function of the path, the configured
/// roots and what `lstat`/`realpath` say: no other state.
public struct SafetyPolicy: Sendable {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)
    }

    public var fileSystem: FileSystem
    public var home: String
    /// Folders whose *contents* may be removed (the scan locations). Never the folders themselves.
    public var dataRoots: [String]
    /// Folders whose `.app` bundles may be removed (/Applications, ~/Applications, ...).
    public var appRoots: [String]
    /// This app's own bundle and identifier: never removed through the normal flow.
    public var selfBundlePath: String?
    public var selfBundleID: String?
    /// Set while uninstalling an Apple app installed from the App Store (`AppIdentity.appStoreAppleID`):
    /// data named after that app (`com.apple.TestFlight`, `com.apple.TestFlight.*`,
    /// `group.com.apple.TestFlight...`) is its own. Every other Apple name stays denied.
    public var appStoreAppleID: String?

    public init(fileSystem: FileSystem, home: String, dataRoots: [String], appRoots: [String],
                selfBundlePath: String? = nil, selfBundleID: String? = nil) {
        self.fileSystem = fileSystem
        self.home = home
        self.dataRoots = dataRoots
        self.appRoots = appRoots
        self.selfBundlePath = selfBundlePath
        self.selfBundleID = selfBundleID
    }

    /// Never removed, and nothing that contains them is removed either.
    public var protectedPaths: [String] {
        let systemPaths = ["/", "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/opt", "/cores", "/dev",
                           "/Library", "/Applications", "/Users", "/Volumes", "/Network",
                           "/System/Applications", "/Library/Apple", "/Library/Keychains"]
        let userPaths = ["", "/Desktop", "/Documents", "/Downloads", "/Movies", "/Music", "/Pictures", "/Public",
                         "/Applications", "/Library", "/Library/Keychains", "/Library/Mobile Documents",
                         "/Library/CloudStorage", "/Library/Mail", "/Library/Messages", "/Library/Photos",
                         "/Library/Accounts", "/Library/Cookies", "/.Trash"].map { home + $0 }
        return systemPaths + userPaths + dataRoots + appRoots
    }

    /// Whole subtrees that are never touched, whatever a scan says about them.
    public var protectedTrees: [String] {
        ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/var/db", "/Library/Apple", "/Library/Keychains",
         home + "/Library/Keychains", home + "/Library/Mobile Documents", home + "/Library/CloudStorage",
         home + "/Library/Mail", home + "/Library/Messages", home + "/.Trash"]
    }

    public func check(_ path: String) -> Verdict {
        // 1. Shape: absolute, normalized, printable. No `..`, no `.`, no empty components.
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/") else { return .denied("not an absolute path") }
        guard !path.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return .denied("control characters in path") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return .denied("path is not normalized") }

        // 2. Protected places, and anything containing one.
        if protectedPaths.contains(path) { return .denied("protected folder") }
        if let tree = protectedTrees.first(where: { Self.isInside(path, $0) }) { return .denied("inside protected folder \(tree)") }
        if let inner = (protectedPaths + protectedTrees).first(where: { Self.isInside($0, path) }) {
            return .denied("contains protected folder \(inner)")
        }

        // 3. No symbolic link on the way: the parent must already be its own canonical path.
        //    (The last component itself may be a link; it is removed as a link, never followed.)
        let parent = (path as NSString).deletingLastPathComponent
        guard let canonicalParent = try? fileSystem.canonicalPath(parent) else { return .denied("cannot resolve parent folder") }
        guard canonicalParent == parent else { return .denied("path goes through a symbolic link (\(canonicalParent))") }
        guard (try? fileSystem.info(path)) != nil else { return .denied("does not exist") }

        // 4. Apple's own data and this app.
        let name = Paths.lastComponent(path)
        let stripped = BundleIDs.stripFileSuffix(name)
        if BundleIDs.isApple(stripped) || OrphanFinder.isAppleComponent(stripped), !ownedByAppStoreAppleApp(stripped) {
            return .denied("Apple component")
        }
        if let selfBundlePath, path == selfBundlePath || Self.isInside(path, selfBundlePath) || Self.isInside(selfBundlePath, path) {
            return .denied("Mac Clean itself")
        }
        if let selfBundleID, BundleIDs.isComponent(BundleIDs.dropHardwareUUID(BundleIDs.stripFileSuffix(name)), of: selfBundleID) {
            return .denied("Mac Clean's own data")
        }

        // 5. Inside a configured root, at least one level down.
        if path.hasSuffix(".app") {
            if let root = appRoots.first(where: { Self.isInside(path, $0) }) {
                // Not an app inside another app's bundle.
                let relative = path.dropFirst(root.count + 1).split(separator: "/").dropLast()
                if relative.contains(where: { $0.hasSuffix(".app") }) { return .denied("inside another app bundle") }
                return .allowed
            }
        }
        if dataRoots.contains(where: { Self.isInside(path, $0) }) {
            // Within a data root, never reach into an app bundle.
            if components.contains(where: { $0.hasSuffix(".app") }) { return .denied("inside an app bundle") }
            return .allowed
        }
        return .denied("outside the folders Mac Clean cleans")
    }

    /// The name belongs to the Apple app being uninstalled: its bundle ID, a component of it, or
    /// that with a `group.` prefix. Never for `com.apple` itself or anything shorter.
    func ownedByAppStoreAppleApp(_ name: String) -> Bool {
        guard let id = appStoreAppleID, id.split(separator: ".").count >= 3 else { return false }
        return BundleIDs.isComponent(BundleIDs.stripGroupPrefix(name), of: id)
    }

    /// `path` is strictly below `folder`.
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        let base = folder == "/" ? "/" : folder + "/"
        return path.hasPrefix(base) && path.count > base.count
    }
}
