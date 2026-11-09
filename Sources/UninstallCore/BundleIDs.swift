import Foundation

/// Helpers for reverse-DNS identifiers and the entry names derived from them.
public enum BundleIDs {
    /// Suffixes the system adds to an identifier to name a file.
    static let fileSuffixes = [".plist", ".savedState", ".binarycookies", ".sfl", ".sfl2", ".sfl3", ".log"]

    /// The identifier an entry in ~/Library is named after: `com.foo.Bar.plist` → `com.foo.Bar`.
    /// ByHost preferences carry a hardware UUID: `com.foo.Bar.0A1B…plist` → `com.foo.Bar.0A1B…`
    /// (callers match it with `isComponent(of:)`).
    public static func stripFileSuffix(_ name: String) -> String {
        for suffix in fileSuffixes where name.lowercased().hasSuffix(suffix.lowercased()) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// A team-prefixed group container: `UBF8T346G9.com.microsoft.teams` → (`UBF8T346G9`, `com.microsoft.teams`).
    public static func splitTeamPrefix(_ name: String) -> (team: String, rest: String)? {
        guard let dot = name.firstIndex(of: ".") else { return nil }
        let team = name[..<dot]
        guard team.count == 10, team.allSatisfy({ $0.isUppercase || $0.isNumber }) else { return nil }
        return (String(team), String(name[name.index(after: dot)...]))
    }

    /// `group.com.foo.shared` → `com.foo.shared`.
    public static func stripGroupPrefix(_ name: String) -> String {
        name.lowercased().hasPrefix("group.") ? String(name.dropFirst(6)) : name
    }

    /// Looks like a reverse-DNS identifier: at least three dot-separated parts, no spaces,
    /// a short alphabetic first part (`com`, `org`, `io`, `me`...).
    public static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !name.contains(" ") else { return false }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let first = parts[0]
        guard (2...10).contains(first.count), first.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// `com.microsoft.Excel` → `com.microsoft`. Nil for identifiers with fewer than three parts.
    public static func vendorPrefix(of id: String) -> String? {
        let parts = id.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts[0] + "." + parts[1]
    }

    /// `candidate` equals `id` or extends it with more components (`id.helper`, `id.ShipIt`).
    /// Compared without case. Never true for a mere string prefix: `com.foo.Bar` is not part of `com.foo.Barcode`.
    public static func isComponent(_ candidate: String, of id: String) -> Bool {
        let c = candidate.lowercased(), i = id.lowercased()
        return c == i || c.hasPrefix(i + ".")
    }

    /// Namespaces shared by unrelated developers: being in one says nothing about the vendor.
    public static let sharedNamespaces: Set<String> = [
        "com.github", "io.github", "com.gitlab", "io.gitlab", "org.sourceforge", "net.sourceforge",
        "com.electron", "org.electron", "com.squirrel", "org.sparkle-project", "com.example", "org.example",
    ]

    /// ByHost files carry the hardware UUID as a last component: `com.foo.bar.<UUID>` → `com.foo.bar`.
    public static func dropHardwareUUID(_ id: String) -> String {
        var parts = id.split(separator: ".", omittingEmptySubsequences: false)
        if let last = parts.last, parts.count > 1 {
            let hex = last.replacingOccurrences(of: "-", with: "")
            if (hex.count == 32 || hex.count == 12) && hex.allSatisfy(\.isHexDigit) { parts.removeLast() }
        }
        return parts.joined(separator: ".")
    }

    /// Apple's own identifiers and groups. Never offered for removal.
    public static func isApple(_ id: String) -> Bool {
        let l = stripGroupPrefix(id).lowercased()
        return l == "com.apple" || l.hasPrefix("com.apple.")
    }
}
