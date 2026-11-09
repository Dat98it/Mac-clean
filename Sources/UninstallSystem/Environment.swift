import UninstallCore
import Foundation

/// Wires Core to either the real machine or a throwaway folder tree (`--sandbox <folder>`), where
/// the home folder, /Library, /Applications and the Trash are all folders inside the tree.
public struct CleanerEnvironment: Sendable {
    public let home: String
    public let systemLibrary: String
    public let appRoots: [String]
    public let locations: [Location]
    public let fileSystem: FileSystem
    public let trasher: Trashing
    public let admin: AdminActing
    public let adminRemover: AdminRemoving
    public let permanentRemover: PermanentRemoving
    public let launchAgents: LaunchAgentUnloading?
    public let trashFolder: String
    public let supportFolder: String
    public let isSandbox: Bool
    public let selfBundlePath: String?
    public let selfBundleID: String?

    public static func live(selfBundlePath: String?, selfBundleID: String?) -> CleanerEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let id = selfBundleID ?? "com.dat98it.MacClean"
        return CleanerEnvironment(
            home: home, systemLibrary: "/Library",
            appRoots: ["/Applications", home + "/Applications"],
            locations: Location.standard(home: home),
            fileSystem: RealFileSystem(), trasher: MacTrasher(), admin: AdministratorScriptRunner(),
            adminRemover: AdministratorScriptRunner(),
            permanentRemover: MacPermanentRemover(), launchAgents: LaunchctlUnloader(),
            trashFolder: home + "/.Trash", supportFolder: home + "/Library/Application Support/" + id,
            isSandbox: false, selfBundlePath: selfBundlePath, selfBundleID: id)
    }

    /// Everything inside `root`. Nothing outside it is read for removal or changed.
    public static func sandbox(root: String, selfBundlePath: String?, selfBundleID: String?) -> CleanerEnvironment {
        let fs = RealFileSystem()
        let canonicalRoot = (try? fs.canonicalPath(root)) ?? root
        let home = canonicalRoot + "/home"
        let library = canonicalRoot + "/Library"
        let trash = home + "/.Trash"
        return CleanerEnvironment(
            home: home, systemLibrary: library, appRoots: [canonicalRoot + "/Applications"],
            locations: Location.standard(home: home, systemLibrary: library),
            fileSystem: fs, trasher: FolderTrasher(folder: trash), admin: SandboxAdmin(), adminRemover: SandboxAdmin(),
            permanentRemover: MacPermanentRemover(), launchAgents: nil,
            trashFolder: trash, supportFolder: home + "/Library/Application Support/" + (selfBundleID ?? "com.dat98it.MacClean"),
            isSandbox: true, selfBundlePath: selfBundlePath, selfBundleID: selfBundleID ?? "com.dat98it.MacClean")
    }

    public var policy: SafetyPolicy {
        SafetyPolicy(fileSystem: fileSystem, home: home, dataRoots: locations.map(\.path), appRoots: appRoots,
                     selfBundlePath: selfBundlePath, selfBundleID: selfBundleID)
    }

    public var trashFolders: [String] {
        guard !isSandbox else { return [trashFolder] }
        var folders = [trashFolder]
        let uid = getuid()
        for volume in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            folders.append("/Volumes/\(volume)/.Trashes/\(uid)")
        }
        return folders
    }

    public var log: ActionLog {
        let file = supportFolder + "/actions.log"
        let folder = supportFolder
        return ActionLog(append: { line in
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if let handle = FileHandle(forWritingAtPath: file) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            } else {
                try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: file))
            }
        })
    }

    public var logFile: String { supportFolder + "/actions.log" }

    public func loadIgnoreList() -> IgnoreList {
        IgnoreList.decode(try? Data(contentsOf: URL(fileURLWithPath: supportFolder + "/ignored.json")))
    }

    public func saveIgnoreList(_ list: IgnoreList) {
        try? FileManager.default.createDirectory(atPath: supportFolder, withIntermediateDirectories: true)
        try? list.encoded().write(to: URL(fileURLWithPath: supportFolder + "/ignored.json"), options: .atomic)
    }

    // MARK: Reading what is installed (slow: call off the main thread)

    public func installedApps() -> [AppIdentity] {
        let roots = isSandbox ? appRoots : InstalledAppSources.appFolders(home: home)
        var seen = Set<String>()
        return InstalledAppSources.findApps(in: roots).compactMap(BundleReader.identity(ofAppAt:)).filter { seen.insert($0.path).inserted }
    }

    public func receipts() -> [PackageReceipt] {
        guard !isSandbox else { return [] }
        return InstalledAppSources.packageIDs().filter { !BundleIDs.isApple($0) }
            .map { PackageReceipt(id: $0, files: InstalledAppSources.packageFiles($0)) }
    }

    public func launchServices() -> (ids: [String: [String]], names: Set<String>) {
        isSandbox ? ([:], []) : InstalledAppSources.launchServicesRecords()
    }

    public func installedIndex(apps: [AppIdentity], receipts: [PackageReceipt]) -> InstalledAppIndex {
        let ls = launchServices()
        let live = isSandbox ? [] : receipts.filter { InstalledAppSources.isPackageLive(files: $0.files) }.map(\.id)
        return InstalledAppIndex(apps: apps, launchServices: ls.ids, launchServicesNames: ls.names, livePackageIDs: live,
                                 runningIDs: InstalledAppSources.runningBundleIDs(),
                                 commandLineTools: isSandbox ? [] : InstalledAppSources.commandLineTools(home: home))
    }
}

/// The administrator step in a sandbox: the same moves, without a password, inside the tree.
struct SandboxAdmin: AdminActing, AdminRemoving {
    func removeForGood(_ paths: [String]) -> [String: Result<String?, AdminError>] {
        var results: [String: Result<String?, AdminError>] = [:]
        for path in paths {
            do { try FileManager.default.removeItem(atPath: path); results[path] = .success(nil) }
            catch { results[path] = .failure(AdminError("\(error)")) }
        }
        return results
    }

    func perform(_ items: [PlannedItem], trashFolder: String) -> [String: Result<String?, AdminError>] {
        var results: [String: Result<String?, AdminError>] = [:]
        for item in items {
            switch item.target {
            case .receipt: results[item.displayPath] = .success(nil)
            case .path(let path, _, _, _):
                do { results[path] = .success(try FolderTrasher(folder: trashFolder).trash(path)) }
                catch { results[path] = .failure(AdminError("\(error)")) }
            }
        }
        return results
    }
}
