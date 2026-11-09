import UninstallCore
import UninstallSystem
import Foundation

// Read-only diagnostics for the uninstaller (adapted from App Clean's appclean-probe). Nothing here
// moves or removes anything.
//   macclean-probe app-scan <App.app>...   what uninstalling these apps would find
//   macclean-probe orphans [--excluded]    left-over data and why other candidates were excluded
enum UninstallProbe {
    static func run(_ args: [String]) {
        let fs = RealFileSystem()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let locations = Location.standard(home: home)

        func now() -> Double { Date().timeIntervalSinceReferenceDate }

        func formatBytes(_ b: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
        }

        func shortPath(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

        func installedApps() -> [AppIdentity] {
            let paths = InstalledAppSources.findApps(in: InstalledAppSources.appFolders(home: home))
            var seen = Set<String>()
            return paths.compactMap(BundleReader.identity(ofAppAt:)).filter { seen.insert($0.path).inserted }
        }

        func receipts() -> [PackageReceipt] {
            InstalledAppSources.packageIDs().filter { !BundleIDs.isApple($0) }
                .map { PackageReceipt(id: $0, files: InstalledAppSources.packageFiles($0)) }
        }

        switch args.first {
        case "app-scan":
            var t = now()
            let apps = installedApps()
            let pkgs = receipts()
            let ls = InstalledAppSources.launchServicesRecords().ids
            print(String(format: "index: %d apps, %d non-Apple packages (%.2fs)", apps.count, pkgs.count, now() - t))
            for path in args.dropFirst() {
                guard let app = BundleReader.identity(ofAppAt: path) else { print("cannot read \(path)"); continue }
                t = now()
                let scanner = Scanner(fileSystem: fs, locations: locations, otherApps: apps, receipts: pkgs, launchServices: ls, userID: getuid())
                let result = scanner.scan(app)
                print("\n== \(app.displayName)  \(app.bundleID)  team=\(app.teamID ?? "-")")
                print("   names=\(app.names) exec=\(app.executableName ?? "-") groups=\(app.appGroups)")
                print("   nested=\(app.nestedBundleIDs.count): \(app.nestedBundleIDs.prefix(8).joined(separator: ", "))")
                var seen = Set<[UInt64]>()
                let sizer = SizeCalculator(fileSystem: fs)
                var total = SizeCalculator.Totals()
                for f in result.findings {
                    let s = f.path.hasPrefix("pkgutil:") ? SizeCalculator.Totals() : sizer.size(of: [f.path], seen: &seen)
                    total.bytes += s.bytes
                    total.naiveBytes += s.naiveBytes
                    let tick = f.preselectedForUninstall ? "[x]" : "[ ]"
                    let shared = f.sharedWith.isEmpty ? "" : "  shared: \(f.sharedWith.joined(separator: ", "))"
                    let unread = s.unreadableCount > 0 ? "  (\(s.unreadableCount) unreadable)" : ""
                    print("   \(tick) \(f.confidence.description.padding(toLength: 6, withPad: " ", startingAt: 0)) \(formatBytes(s.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(shortPath(f.path))  — \(f.reason)\(shared)\(unread)")
                }
                for u in result.unreadable { print("   !! unreadable \(shortPath(u.path)): \(u.error)") }
                print(String(format: "   total %@ (naive %@), %.2fs", formatBytes(total.bytes), formatBytes(total.naiveBytes), now() - t))
            }

        case "orphans":
            var t = now()
            let apps = installedApps()
            let (ls, lsNames) = InstalledAppSources.launchServicesRecords()
            let tLS = now() - t
            let livePkgs = InstalledAppSources.packageIDs().filter { !BundleIDs.isApple($0) }
                .filter { InstalledAppSources.isPackageLive(files: InstalledAppSources.packageFiles($0)) }
            let index = InstalledAppIndex(apps: apps, launchServices: ls, launchServicesNames: lsNames, livePackageIDs: livePkgs,
                                          runningIDs: InstalledAppSources.runningBundleIDs(),
                                          commandLineTools: InstalledAppSources.commandLineTools(home: home))
            print(String(format: "index: %d apps, %d LaunchServices ids (%.2fs), live packages %@ (%.2fs total)",
                         apps.count, ls.count, tLS, livePkgs.description, now() - t))
            t = now()
            let result = OrphanFinder(fileSystem: fs, locations: locations, index: index).find()
            print(String(format: "find: %.2fs, %d candidate groups, %d excluded", now() - t, result.groups.count, result.excluded.count))
            t = now()
            let sizer = SizeCalculator(fileSystem: fs)
            var seen = Set<[UInt64]>()
            let sized = result.groups.map { g in (g, sizer.size(of: g.entries.map(\.path), seen: &seen)) }
                .sorted { $0.1.bytes > $1.1.bytes }
            print(String(format: "size: %.2fs", now() - t))
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            for (g, s) in sized {
                print("\n# \(g.key)  \(formatBytes(s.bytes)) (naive \(formatBytes(s.naiveBytes)))  last modified \(df.string(from: g.lastModified))")
                for e in g.entries { print("    \(e.kind.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(e.confidence) \(shortPath(e.path)) \(e.linkReason ?? "")") }
            }
            print("\nuncertain (same vendor installed): \(result.uncertain.map { "\($0.group.key) [\($0.detail)]" }.joined(separator: ", "))")
            print("\nunknown owner:")
            for g in result.unknownOwner {
                let s = sizer.size(of: g.entries.map(\.path), seen: &seen)
                print("    \(formatBytes(s.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(shortPath(g.entries[0].path))")
            }
            for u in result.unreadable { print("!! unreadable \(shortPath(u.path)): \(u.error)") }
            print("\nexcluded by reason:")
            let byReason = Dictionary(grouping: result.excluded, by: \.reason)
            for reason in OrphanExclusion.allCases { print("  \(reason.rawValue): \(byReason[reason]?.count ?? 0)") }
            if args.contains("--excluded") {
                for reason in OrphanExclusion.allCases where reason != .apple {
                    for e in byReason[reason] ?? [] { print("  [\(reason.rawValue)] \(e.group.key) ← \(e.detail)") }
                }
            }

        default:
            print("usage: macclean-probe app-scan <App.app>... | orphans [--excluded]")
        }
    }
}
