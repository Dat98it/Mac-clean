#!/usr/bin/env bash
# Mutation check for the uninstaller's safety-critical code (UninstallCore): breaks one guard at a time (a Perl substitution),
# runs the tests, and expects them to fail. A mutation the tests do not catch is reported as SURVIVED.
# Every file is restored after each mutation, also on Ctrl-C.
# Usage: Scripts/mutate_uninstall.sh [name-filter]   (Scripts/mutate_all.sh runs this and mutate.py)
set -uo pipefail
cd "$(dirname "$0")/.."

C=Sources/UninstallCore
# name | file | perl substitution (applied once with -0pi)
MUTATIONS=(
"policy-protected-paths|$C/SafetyPolicy.swift|s/if protectedPaths.contains\(path\) \{/if false \&\& protectedPaths.contains(path) {/"
"policy-protected-trees|$C/SafetyPolicy.swift|s/if let tree = protectedTrees.first/if false, let tree = protectedTrees.first/"
"policy-contains-protected|$C/SafetyPolicy.swift|s/if let inner = \(protectedPaths \+ protectedTrees\).first/if false, let inner = (protectedPaths + protectedTrees).first/"
"policy-dotdot|$C/SafetyPolicy.swift|s/\\\$0 == \"\.\.\" \}\) else/false }) else/"
"policy-symlink-parent|$C/SafetyPolicy.swift|s/guard canonicalParent == parent else/guard true else/"
"policy-apple|$C/SafetyPolicy.swift|s/return .denied\(\"Apple component\"\)/_ = 0/"
"policy-apple-own-length|$C/SafetyPolicy.swift|s/id.split\(separator: \".\"\).count >= 3/true/"
"policy-apple-own-component|$C/SafetyPolicy.swift|s/return BundleIDs.isComponent\(BundleIDs.stripGroupPrefix\(name\), of: id\)/return true/"
"builtin-apple-system|$C/BundleIDs.swift|s/if path.hasPrefix\(\"\/System\/\"\) \{ return true \}//"
"builtin-apple-receipt|$C/BundleIDs.swift|s/return isApple\(bundleID\) \&\& !hasAppStoreReceipt/return false/"
"appstore-apple-id-receipt|$C/Model.swift|s/hasAppStoreReceipt \&\& BundleIDs.isApple\(bundleID\) \?/BundleIDs.isApple(bundleID) ?/"
"scanner-apple-vendor|$C/Scanner.swift|s/, !BundleIDs.isApple\(vendor\),/,/"
"scanner-apple-vendor-folder|$C/Scanner.swift|s/if BundleIDs.isApple\(app.bundleID\) \{ return nil \}//"
"policy-self-bundle|$C/SafetyPolicy.swift|s/return .denied\(\"Mac Clean itself\"\)/return .allowed/"
"policy-self-data|$C/SafetyPolicy.swift|s/return .denied\(\"Mac Clean's own data\"\)/return .allowed/"
"policy-outside-roots|$C/SafetyPolicy.swift|s/return .denied\(\"outside the folders Mac Clean cleans\"\)/return .allowed/"
"policy-app-in-app|$C/SafetyPolicy.swift|s/return .denied\(\"inside another app bundle\"\)/return .allowed/"
"plan-only-selected|$C/Actions.swift|s/where selected.contains\(finding.path\) \&\&/where/"
"plan-policy|$C/Actions.swift|s/if case .denied\(let reason\) = policy.check\(finding.path\) \{/if false, case .denied(let reason) = policy.check(finding.path) {/"
"plan-receipt-id|$C/Actions.swift|s/guard finding.kind == .receipt, ReceiptID.isValid\(id\) else/guard finding.kind == .receipt else/"
"remover-recheck|$C/Actions.swift|s/guard case .path\(let path, let device, let inode, let type\) = item.target else \{ return nil \}/return nil;/"
"remover-admin-consent|$C/Actions.swift|s/guard includeAdmin, admin != nil else/guard admin != nil else/"
"permanent-in-trash|$C/Actions.swift|s/guard trashFolders.contains\(\(path as NSString\).deletingLastPathComponent\),/guard true,/"
"permanent-inode|$C/Actions.swift|s/guard info.inode == record.inode, info.device == record.device else/guard true else/"
"admin-quote|$C/Actions.swift|s/\"'\" \+ s.replacingOccurrences\(of: \"'\", with: \"'\\\\\\\\''\"\) \+ \"'\"/\"'\" + s + \"'\"/"
"orphan-apple|$C/OrphanFinder.swift|s/if ids.contains\(where: \{ BundleIDs.isApple\(\\\$0\) \|\| Self.isAppleComponent\(\\\$0\) \}\) \{ return \(.apple, group.key\) \}//"
"orphan-apple-component|$C/OrphanFinder.swift|s/if appleInherited.contains\(where: \{ BundleIDs.isComponent\(l, of: \\\$0\) \}\) \{ return true \}//"
"orphan-installed|$C/OrphanFinder.swift|s/if let app = index.apps.first\(where: \{ \\\$0.allIDs.contains\(id\) \}\) \{ return \(.installed, app.path\) \}//"
"orphan-related|$C/OrphanFinder.swift|s/if let other = installedIDs.first\(where: \{ related\(id, \\\$0\) \}\) \{ return \(.relatedToInstalled, other\) \}//"
"orphan-unplugged-disk|$C/OrphanFinder.swift|s/if let first = paths.first \{ return \(.maybeOnUnpluggedDisk, first\) \}//"
"orphan-same-vendor|$C/OrphanFinder.swift|s/vendors.contains\(vendor\), !BundleIDs.sharedNamespaces/false, !BundleIDs.sharedNamespaces/"
"orphan-same-team|$C/OrphanFinder.swift|s/teams.contains\(team\) \{/false {/"
"orphan-cli|$C/OrphanFinder.swift|s/index.commandLineTools.contains\(\\\$0\) \}\)/false })/"
"orphan-library|$C/OrphanFinder.swift|s/if let lib = ids.first\(where: \{ id in Self.libraryPrefixes/if false, let lib = ids.first(where: { id in Self.libraryPrefixes/"
"orphan-recent|$C/OrphanFinder.swift|s/if now.timeIntervalSince\(group.lastModified\) < recentInterval/if false/"
"orphan-ignored|$C/OrphanFinder.swift|s/return \(.ignoredByUser, group.key\)/_ = 0/"
"orphan-running|$C/OrphanFinder.swift|s/return \(.running, other\)/continue/"
"orphan-name-known|$C/OrphanFinder.swift|s/if known.contains\(lower\) \|\| Self.devToolFolders.contains\(lower\)/if false/"
"preselect-low|$C/Model.swift|s/case .low: return false/case .low: return true/"
"preselect-shared|$C/Model.swift|s/guard domain == .user, sharedWith.isEmpty else/guard domain == .user else/"
"preselect-admin|$C/Model.swift|s/guard domain == .user, sharedWith.isEmpty else/guard sharedWith.isEmpty else/"
"ownership-admin|$C/FileSystem.swift|s/return owner == userID \? .user : .system/return .user/"
"permanent-admin-routing|$C/Actions.swift|s/if Ownership.domain\(of: record.trashed, default: .user, fileSystem: fileSystem, userID: userID\) == .system \{\n                forAdmin.append/if false {\n                forAdmin.append/"
"permanent-admin-unchecked|$C/Actions.swift|s/if let problem = check\(record\) \{\n                outcomes/if false, let problem = check(record) {\n                outcomes/"
"removal-quote|$C/Actions.swift|s/let q = quote\(path\)/let q = path/"
"component-boundary|$C/BundleIDs.swift|s/c.hasPrefix\(i \+ \".\"\)/c.hasPrefix(i)/"
"scanner-specific-owner|$C/Scanner.swift|s/if let otherID, otherID.count > own.count \{ return nil \}//"
"scanner-team-mismatch|$C/Scanner.swift|s/if let team, let appTeam = app.teamID, team.team != appTeam \{ return nil \}\n            let reason/let reason/"
)

survived=()
caught=0
for entry in "${MUTATIONS[@]}"; do
    IFS='|' read -r name file expr <<<"$entry"
    [[ -n "${1:-}" && "$name" != *"$1"* ]] && continue
    backup="$(mktemp)"
    cp "$file" "$backup"
    trap 'cp "$backup" "$file"; exit 130' INT TERM
    perl -0pi -e "$expr" "$file"
    if cmp -s "$file" "$backup"; then
        echo "NOT APPLIED  $name (pattern did not match)"
        survived+=("$name (not applied)")
        rm "$backup"
        continue
    fi
    if Scripts/test.sh --filter UninstallCoreTests >/dev/null 2>&1; then
        echo "SURVIVED     $name"
        survived+=("$name")
    else
        echo "caught       $name"
        caught=$((caught + 1))
    fi
    cp "$backup" "$file"
    rm "$backup"
    trap - INT TERM
done
echo "caught $caught, survived ${#survived[@]}"
[[ ${#survived[@]} -eq 0 ]]
