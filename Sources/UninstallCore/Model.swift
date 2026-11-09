import Foundation

/// How sure we are that a path belongs to the app. Low-confidence findings are never pre-selected.
public enum Confidence: Int, Comparable, Sendable, CustomStringConvertible {
    case low, medium, high

    public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}

/// What kind of data a location holds. Decides the warning shown next to it.
public enum DataKind: String, Sendable {
    case appBundle, cache, log, preferences, savedState, webData, userData, launchItem, helper, receipt, scripts

    /// Data the user may care about (save games, databases, licences). Shown with a warning.
    public var mayHoldUserData: Bool {
        switch self {
        case .userData, .preferences: true
        default: false
        }
    }
}

/// Who owns a location: the user, or the system (needs an administrator to change).
public enum Domain: String, Sendable {
    case user, system
}

/// A folder that is searched, one level deep, for entries belonging to an app.
public struct Location: Sendable, Hashable {
    public var path: String
    public var kind: DataKind
    public var domain: Domain

    public init(_ path: String, _ kind: DataKind, _ domain: Domain) {
        self.path = path
        self.kind = kind
        self.domain = domain
    }

    /// The standard places, relative to a home folder and to the system `/Library`.
    public static func standard(home: String, systemLibrary: String = "/Library") -> [Location] {
        let lib = home + "/Library"
        return [
            Location(lib + "/Application Support", .userData, .user),
            Location(lib + "/Caches", .cache, .user),
            Location(lib + "/Preferences", .preferences, .user),
            Location(lib + "/Preferences/ByHost", .preferences, .user),
            Location(lib + "/Containers", .userData, .user),
            Location(lib + "/Group Containers", .userData, .user),
            Location(lib + "/Logs", .log, .user),
            Location(lib + "/Saved Application State", .savedState, .user),
            Location(lib + "/HTTPStorages", .webData, .user),
            Location(lib + "/WebKit", .webData, .user),
            Location(lib + "/Cookies", .webData, .user),
            Location(lib + "/LaunchAgents", .launchItem, .user),
            Location(lib + "/Application Scripts", .scripts, .user),
            Location(systemLibrary + "/Application Support", .userData, .system),
            Location(systemLibrary + "/Caches", .cache, .system),
            Location(systemLibrary + "/Preferences", .preferences, .system),
            Location(systemLibrary + "/Logs", .log, .system),
            Location(systemLibrary + "/LaunchAgents", .launchItem, .system),
            Location(systemLibrary + "/LaunchDaemons", .launchItem, .system),
            Location(systemLibrary + "/PrivilegedHelperTools", .helper, .system),
        ]
    }
}

/// What we know about an app, read from its bundle by the system layer.
public struct AppIdentity: Sendable, Hashable {
    public var bundleID: String
    public var path: String
    /// CFBundleDisplayName / CFBundleName / the bundle's file name without `.app`.
    public var names: [String]
    public var executableName: String?
    public var teamID: String?
    /// `com.apple.security.application-groups` from the signature's entitlements.
    public var appGroups: [String]
    /// Identifiers of bundles inside this one: helpers, login items, XPC services, extensions.
    public var nestedBundleIDs: [String]

    public init(bundleID: String, path: String, names: [String], executableName: String? = nil,
                teamID: String? = nil, appGroups: [String] = [], nestedBundleIDs: [String] = []) {
        self.bundleID = bundleID
        self.path = path
        self.names = names
        self.executableName = executableName
        self.teamID = teamID
        self.appGroups = appGroups
        self.nestedBundleIDs = nestedBundleIDs
    }

    /// The vendor part of the identifier: `com.microsoft` for `com.microsoft.Excel`.
    public var vendorPrefix: String? { BundleIDs.vendorPrefix(of: bundleID) }

    /// Every identifier this app owns, in lower case.
    public var allIDs: Set<String> {
        Set(([bundleID] + nestedBundleIDs).map { $0.lowercased() })
    }
}

/// Why a path was matched to an app. Shown to the user next to each finding.
public enum MatchReason: Sendable, Hashable, CustomStringConvertible {
    case appBundle
    case bundleID(String)
    case bundleIDComponent(String)
    case nestedBundleID(String)
    case appGroup(String)
    case sameVendor(String)
    case name(String)
    case launchItemProgram(String)
    case receipt(String)

    public var description: String {
        switch self {
        case .appBundle: "the app itself"
        case .bundleID(let id): "bundle ID \(id)"
        case .bundleIDComponent(let id): "belongs to \(id)"
        case .nestedBundleID(let id): "helper/extension \(id)"
        case .appGroup(let g): "app group \(g)"
        case .sameVendor(let v): "same vendor \(v), no other app of theirs installed"
        case .name(let n): "name \"\(n)\""
        case .launchItemProgram(let p): "launch item runs \(p)"
        case .receipt(let r): "installer receipt \(r)"
        }
    }
}

public struct Finding: Sendable, Hashable {
    public var path: String
    public var kind: DataKind
    public var domain: Domain
    public var confidence: Confidence
    public var reason: MatchReason
    /// Other installed apps that look like they use the same data (same vendor or team).
    public var sharedWith: [String]

    public init(path: String, kind: DataKind, domain: Domain, confidence: Confidence,
                reason: MatchReason, sharedWith: [String] = []) {
        self.path = path
        self.kind = kind
        self.domain = domain
        self.confidence = confidence
        self.reason = reason
        self.sharedWith = sharedWith
    }

    /// Uninstall mode starts with these ticked: the app itself, high-confidence matches, and
    /// medium matches by a distinctive name. Never anything low, shared, or needing an administrator.
    /// Clean-up mode ticks nothing (see `OrphanFinder`).
    public var preselectedForUninstall: Bool {
        guard domain == .user, sharedWith.isEmpty else { return false }
        switch confidence {
        case .high: return true
        case .medium:
            if case .name = reason { return true }
            return false
        case .low: return false
        }
    }
}
