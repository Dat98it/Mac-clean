import Foundation
import MacCleanCore

/// Wires Core to either the real machine or a throwaway folder tree (`--sandbox <folder>`).
/// Adapted from App Clean's CleanerEnvironment.
///
/// In a sandbox, `<folder>` plays the startup disk (its home folder is `<folder>/home`) and every
/// folder in `<folder>/Volumes` plays an external disk. A disk with a `.timemachine` folder plays
/// a Time Machine backup; one with a `.readonly` file plays a read-only disk. Removing a folder
/// from `<folder>/Volumes` plays unplugging it. Nothing outside `<folder>` is changed.
public struct MacCleanEnvironment: Sendable {
    public let home: String
    public let userID: UInt32
    public let isSandbox: Bool
    public let sandboxRoot: String?
    public let fileSystem: FileSystem
    public let reader: DirectoryReading
    public let trasher: Trashing
    public let admin: AdminActing & AdminRemoving
    public let permanentRemover: PermanentRemoving
    public let openFiles: OpenFileChecking
    public let mounts: MountChecking
    public let firmlinks: FirmlinkMap
    public let supportFolder: String
    public let selfBundlePath: String?

    public static let bundleID = "local.macclean.app"

    public static func live(selfBundlePath: String?) -> MacCleanEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let firmlinks = VolumeCatalog.firmlinks()
        return MacCleanEnvironment(
            home: home, userID: getuid(), isSandbox: false, sandboxRoot: nil, fileSystem: RealFileSystem(), reader: BulkDirectoryReader(),
            trasher: MacTrasher(), admin: AdministratorScriptRunner(), permanentRemover: MacPermanentRemover(),
            openFiles: OpenFileChecker(firmlinks: firmlinks), mounts: SystemMounts(), firmlinks: firmlinks,
            supportFolder: home + "/Library/Application Support/" + bundleID, selfBundlePath: selfBundlePath)
    }

    /// Everything inside `root`. Nothing outside it is changed.
    public static func sandbox(root: String, selfBundlePath: String?) -> MacCleanEnvironment {
        let fs = RealFileSystem()
        let canonicalRoot = (try? fs.canonicalPath(root)) ?? root
        let home = canonicalRoot + "/home"
        let uid = getuid()
        let volumesFolder = canonicalRoot + "/Volumes"
        let trashFor: @Sendable (String) -> String = { path in
            // The sandbox volume holding the path decides which "Trash" it goes to.
            if Paths.isInside(path, volumesFolder), let name = path.dropFirst(volumesFolder.count + 1).split(separator: "/").first {
                return volumesFolder + "/" + name + "/.Trashes/" + String(uid)
            }
            return home + "/.Trash"
        }
        return MacCleanEnvironment(
            home: home, userID: uid, isSandbox: true, sandboxRoot: canonicalRoot, fileSystem: fs, reader: BulkDirectoryReader(),
            trasher: FolderTrasher(folderFor: trashFor), admin: SandboxAdmin(), permanentRemover: MacPermanentRemover(),
            openFiles: OpenFileChecker(firmlinks: FirmlinkMap(linked: [])), mounts: SandboxMounts(root: canonicalRoot),
            firmlinks: FirmlinkMap(linked: []), supportFolder: home + "/Library/Application Support/" + bundleID,
            selfBundlePath: selfBundlePath)
    }

    /// The volumes to offer, read now.
    public func volumes() -> [Volume] {
        guard let root = sandboxRoot else { return VolumeCatalogRules.volumes(from: VolumeCatalog.mounts()) }
        var result = [Volume(name: "Sandbox HD", mountPoint: root, scanRoot: root, kind: .startupData, fileSystemType: "apfs", isReadOnly: false)]
        let folder = root + "/Volumes"
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() where !name.hasPrefix(".") {
            let mount = folder + "/" + name
            let fm = FileManager.default
            result.append(Volume(name: name, mountPoint: mount, scanRoot: mount,
                                 kind: fm.fileExists(atPath: mount + "/.timemachine") ? .timeMachine : .external,
                                 fileSystemType: "apfs", isReadOnly: fm.fileExists(atPath: mount + "/.readonly")))
        }
        return result
    }

    /// The store for a volume: the startup disk is scanned under /System/Volumes/Data and shown
    /// with firmlink paths.
    public func firmlinks(for volume: Volume) -> FirmlinkMap? {
        volume.kind == .startupData && !isSandbox ? firmlinks : nil
    }

    public func policy(volumes: [Volume], allowlist: [String]) -> SafetyPolicy {
        SafetyPolicy(fileSystem: fileSystem, home: home, volumes: volumes, allowlist: allowlist, selfBundlePath: selfBundlePath)
    }

    public func trashFolder(forMountPoint mountPoint: String) -> String {
        if let root = sandboxRoot, mountPoint == root { return home + "/.Trash" }
        return TrashLocation.folder(forMountPoint: mountPoint, home: home, userID: userID)
    }

    public func remover(volumes: [Volume], allowlist: [String]) -> Remover {
        let env = self
        return Remover(policy: policy(volumes: volumes, allowlist: allowlist), trasher: trasher, admin: admin, openFiles: openFiles,
                       mounts: mounts, log: log, trashFolder: { env.trashFolder(forMountPoint: $0) })
    }

    public func permanentDeleter(volumes: [Volume]) -> PermanentDeleter {
        PermanentDeleter(fileSystem: fileSystem, remover: permanentRemover, admin: admin, userID: userID,
                         trashFolders: volumes.map { trashFolder(forMountPoint: $0.mountPoint) }, log: log)
    }

    public var logFile: String { supportFolder + "/actions.log" }

    public var log: ActionLog {
        let file = logFile
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
            do { results[item.path] = .success(try FolderTrasher(folderFor: { _ in trashFolder }).trash(item.path)) }
            catch { results[item.path] = .failure(AdminError("\(error)")) }
        }
        return results
    }
}

/// A sandbox disk is "mounted" while its folder exists.
struct SandboxMounts: MountChecking {
    let root: String
    func mountedVolumes() -> Set<String> {
        let folder = root + "/Volumes"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return Set([root] + names.map { folder + "/" + $0 })
    }
}
