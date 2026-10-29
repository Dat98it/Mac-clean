#!/usr/bin/env python3 -I
"""Mutation check for every safety gate: breaks one guard at a time (a literal text replacement),
runs the tests, and expects them to fail. A mutation the tests do not catch is reported as SURVIVED.
Every file is restored after each mutation, also on Ctrl-C.

Adapted from App Clean's Scripts/mutate.sh (same idea; literal replacements instead of Perl regexes).
Usage: Scripts/mutate.py [name-filter]
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
C = "Sources/MacCleanCore/"

# name, file, text to find (must occur), replacement (first occurrence only)
MUTATIONS = [
    # SafetyPolicy.check
    ("policy-absolute", C + "SafetyPolicy.swift",
     'guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/") else', "guard true else"),
    ("policy-control-chars", C + "SafetyPolicy.swift",
     'guard !path.contains(where: { $0 == "\\n" || $0 == "\\r" || $0 == "\\0" }) else', "guard true else"),
    ("policy-shape-used", C + "SafetyPolicy.swift", "if let problem = Self.shapeProblem(path) { return .denied(problem) }", ""),
    ("policy-normalized", C + "SafetyPolicy.swift",
     'guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else', "guard true else"),
    ("policy-protected-paths", C + "SafetyPolicy.swift", "if protectedPaths.contains(path) {", "if false {"),
    ("policy-protected-trees", C + "SafetyPolicy.swift",
     "if let tree = protectedTrees.first(where: { Paths.isWithin(path, $0) })",
     "if false, let tree = protectedTrees.first(where: { Paths.isWithin(path, $0) })"),
    ("policy-contains-protected", C + "SafetyPolicy.swift",
     "if let inner = (protectedPaths + protectedTrees).first(where: { Paths.isInside($0, path) })",
     "if false, let inner = (protectedPaths + protectedTrees).first(where: { Paths.isInside($0, path) })"),
    ("policy-trash", C + "SafetyPolicy.swift",
     'if components.contains(where: { $0 == ".Trashes" || $0 == ".Trash" })', "if false"),
    ("policy-photos", C + "SafetyPolicy.swift",
     'if components.contains(where: { $0.hasSuffix(".photoslibrary")', 'if false && components.contains(where: { $0.hasSuffix(".photoslibrary")'),
    ("policy-symlink-parent", C + "SafetyPolicy.swift", "guard canonicalParent == parent else", "guard true else"),
    ("policy-exists", C + "SafetyPolicy.swift", "guard (try? fileSystem.info(path)) != nil else", "guard true else"),
    ("policy-unknown-volume", C + "SafetyPolicy.swift",
     "guard let volume = VolumeCatalogRules.volume(containing: path, in: volumes) else",
     "guard let volume = VolumeCatalogRules.volume(containing: path, in: volumes) ?? volumes.first else"),
    ("policy-time-machine", C + "SafetyPolicy.swift",
     'if volume.kind == .timeMachine { return .denied("Time Machine backup: view only") }', ""),
    ("policy-read-only", C + "SafetyPolicy.swift", 'if !volume.canTrash { return .denied("volume is read-only") }', ""),
    ("policy-bookkeeping", C + "SafetyPolicy.swift", "ScanRules.systemFolderNames.contains(String(first)) {", "false {"),
    ("policy-self", C + "SafetyPolicy.swift", "if let selfBundlePath, Paths.isWithin", "if false, let selfBundlePath, Paths.isWithin"),
    ("policy-outside-zones", C + "SafetyPolicy.swift",
     'return .denied("outside the folders Mac Clean may clean")', "return .allowed"),
    ("policy-zone-external-only", C + "SafetyPolicy.swift",
     "if volume.kind == .external && Paths.isInside(path, volume.mountPoint)", "if Paths.isInside(path, volume.mountPoint)"),
    ("allowlist-too-broad", C + "SafetyPolicy.swift",
     'if tooBroad.contains(folder) || volumes.contains(where: { $0.mountPoint == folder }) { return .denied("folder is too broad") }', ""),
    ("allowlist-symlink", C + "SafetyPolicy.swift",
     "guard let canonical = try? fileSystem.canonicalPath(folder), canonical == folder else", "guard true else"),
    # Volumes
    ("volume-ntfs", C + "Volume.swift", "&& !Self.ntfsTypes.contains(fileSystemType)", ""),
    ("volume-read-only", C + "Volume.swift", "!isReadOnly && kind != .timeMachine", "kind != .timeMachine"),
    ("volume-startup-not-volumes", C + "Volume.swift",
     ' && !($0.kind == .startupData && Paths.isInside(path, "/Volumes"))', ""),
    ("volume-network-skipped", C + "Volume.swift",
     "if !m.isLocal || networkTypes.contains(m.fileSystemType) || m.fileSystemType == \"devfs\" { continue }",
     "if m.fileSystemType == \"devfs\" { continue }"),
    ("volume-time-machine", C + "Volume.swift",
     "let kind: Volume.Kind = m.hasTimeMachineMarkers ? .timeMachine : .external", "let kind: Volume.Kind = .external"),
    # Deletion plan
    ("plan-root", C + "Actions.swift", "guard Int(id) < store.count, id != 0 else", "guard Int(id) < store.count else"),
    ("plan-nested", C + "Actions.swift",
     "if store.parent(of: id).flatMap({ firstTicked(from: $0, in: ticked, store: store) }) != nil { continue }", ""),
    ("plan-policy", C + "Actions.swift", "= policy.check(path) {", "= SafetyPolicy.Verdict.allowed {"),
    ("plan-kind", C + "Actions.swift", "guard matches(store.kind(id), info.type) else", "guard true else"),
    ("plan-ownership", C + "Actions.swift",
     "ownership: Ownership.of(path, fileSystem: policy.fileSystem, userID: userID)", "ownership: .user"),
    ("ownership-other", C + "FileSystem.swift", "return owner == userID ? .user : .administrator", "return .user"),
    # Remover
    ("remover-mounted", C + "Actions.swift", "mounted.contains(volume.mountPoint) else", "true else"),
    ("remover-policy", C + "Actions.swift", "if case .denied(let reason) = policy.check(item.path) { return reason }", ""),
    ("remover-in-use", C + "Actions.swift", 'if let process = inUse[item.path] { return "in use by \\(process)" }', ""),
    ("remover-identity", C + "Actions.swift",
     "guard now.device == item.device, now.inode == item.inode, now.type == item.type else", "guard true else"),
    ("remover-size-date", C + "Actions.swift",
     'if item.checkSizeAndDate, now.size != item.size || now.modified != item.modified { return "changed since the scan" }', ""),
    ("remover-admin-consent", C + "Actions.swift", "guard includeAdmin, admin != nil else", "guard admin != nil else"),
    ("remover-volume-trash", C + "Actions.swift", "trashFolder: trashFolder(mountPoint)", 'trashFolder: trashFolder("/")'),
    # Permanent deletion
    ("permanent-in-trash", C + "Actions.swift", "guard trashFolders.contains(Paths.parent(path)),", "guard true,"),
    ("permanent-inode", C + "Actions.swift",
     "guard info.inode == record.inode, info.device == record.device else", "guard true else"),
    ("permanent-admin-routing", C + "Actions.swift",
     "if Ownership.of(record.trashed, fileSystem: fileSystem, userID: userID) == .administrator {", "if false {"),
    ("admin-quote", C + "Actions.swift", "\"'\" + s.replacingOccurrences(of: \"'\", with: \"'\\\\''\") + \"'\"", "\"'\" + s + \"'\""),
    ("removal-line-breaks", C + "Actions.swift",
     'for path in paths where !path.contains(where: { $0 == "\\n" || $0 == "\\r" || $0 == "\\0" }) {', "for path in paths {"),
    # Scanner
    ("scan-real-device", C + "Scanner.swift", "if e.isMountPoint || e.realDevice != rootDevice {", "if e.isMountPoint {"),
    ("scan-mount-point", C + "Scanner.swift", "if e.isMountPoint || e.realDevice != rootDevice {", "if e.realDevice != rootDevice {"),
    ("scan-symlink-not-followed", C + "Scanner.swift", "record.kind = .symlink\n",
     "record.kind = .symlink\n                folders.append((records.count, Paths.join(work.path, e.name)))\n"),
    ("scan-hard-links", C + "Scanner.swift", "for h in hardLinked where !run.hardLinks.insert(h.key).inserted {", "for h in hardLinked where false {"),
    ("scan-system-folders", C + "Scanner.swift",
     "if work.depth == 0 && e.type == .directory && ScanRules.systemFolderNames.contains(e.name) {", "if false {"),
    ("scan-fat-birth", C + "Scanner.swift", "birth: volume.hasBirthTime ? ScanRules.clamp(e.birth) : 0", "birth: ScanRules.clamp(e.birth)"),
    ("store-order", C + "NodeStore.swift", "guard Int(batch.firstID) == count else { return false }", ""),
    # Suggestions never select
    ("suggestion-unselected", C + "Suggestions.swift", "public var isSelected: Bool = false", "public var isSelected: Bool = true"),
]


def run_tests(attempts=2):
    # A run that ends without a test report (a build error, or the toolchain's TestingMacros quirk
    # outlasting Scripts/test.sh's retries) is tried once more before it counts as BUILD-FAILED.
    for _ in range(attempts):
        result = subprocess.run([os.path.join(ROOT, "Scripts/test.sh")], cwd=ROOT, capture_output=True, text=True)
        output = result.stdout + result.stderr
        if "Test run" in output:
            return "KILLED" if result.returncode != 0 else "SURVIVED"
    return "BUILD-FAILED"


def main():
    name_filter = sys.argv[1] if len(sys.argv) > 1 else ""
    survived = []
    for name, path, find, replace in MUTATIONS:
        if name_filter not in name:
            continue
        full = os.path.join(ROOT, path)
        with open(full, encoding="utf-8") as f:
            original = f.read()
        if find not in original:
            print(f"MISSING  {name}: text not found in {path}")
            survived.append(name)
            continue
        try:
            with open(full, "w", encoding="utf-8") as f:
                f.write(original.replace(find, replace, 1))
            status = run_tests()
        finally:
            with open(full, "w", encoding="utf-8") as f:
                f.write(original)
        print(f"{status:9} {name}", flush=True)
        if status != "KILLED":
            survived.append(name)
    print(f"\n{len(survived)} not killed" + (": " + ", ".join(survived) if survived else ""))
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
