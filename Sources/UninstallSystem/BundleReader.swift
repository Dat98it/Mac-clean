import UninstallCore
import Foundation
import Security

/// Reads an app bundle's identity: Info.plist, signing team, app groups, nested bundles. Read-only.
public enum BundleReader {
    static let nestedExtensions: Set<String> = ["app", "appex", "xpc", "systemextension"]

    public static func identity(ofAppAt path: String) -> AppIdentity? {
        let url = URL(fileURLWithPath: path)
        guard let info = infoPlist(url), let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        var names: [String] = []
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let n = info[key] as? String, !n.isEmpty, !names.contains(n) { names.append(n) }
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        if !names.contains(fileName) { names.append(fileName) }
        let signing = signingInfo(codeRoot(url).lastPathComponent == "Contents" ? url : codeRoot(url))
        return AppIdentity(bundleID: bundleID, path: path, names: names,
                           executableName: info["CFBundleExecutable"] as? String,
                           teamID: signing.team, appGroups: signing.groups,
                           nestedBundleIDs: nestedBundleIDs(url),
                           hasAppStoreReceipt: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path))
    }

    /// macOS bundles keep Info.plist in `Contents/`; iPhone/iPad apps (and their extensions) keep it
    /// at the top, and an installed iPad app is a wrapper whose real bundle is `Wrapper/<Name>.app`.
    static func infoPlist(_ bundle: URL) -> [String: Any]? {
        let candidates = [
            bundle.appendingPathComponent("Contents/Info.plist"),
            bundle.appendingPathComponent("Info.plist"),
            bundle.appendingPathComponent("Wrapper").appendingPathComponent(bundle.lastPathComponent).appendingPathComponent("Info.plist"),
        ]
        for plist in candidates {
            if let data = try? Data(contentsOf: plist),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return dict
            }
        }
        return nil
    }

    /// The folder that holds the bundle's code: `Contents`, or the wrapped iPad bundle.
    static func codeRoot(_ bundle: URL) -> URL {
        let wrapped = bundle.appendingPathComponent("Wrapper").appendingPathComponent(bundle.lastPathComponent)
        if FileManager.default.fileExists(atPath: wrapped.path) { return wrapped }
        return bundle.appendingPathComponent("Contents")
    }

    static func signingInfo(_ bundle: URL) -> (team: String?, groups: [String]) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return (nil, []) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return (nil, []) }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        return (team, groups)
    }

    /// Identifiers of helpers, login items, XPC services and extensions anywhere inside the bundle.
    static func nestedBundleIDs(_ bundle: URL) -> [String] {
        let contents = codeRoot(bundle)
        guard let walker = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        var ids: [String] = []
        for case let url as URL in walker {
            let ext = url.pathExtension
            if ext == "lproj" || url.lastPathComponent == "Resources" && ext.isEmpty { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            if nestedExtensions.contains(ext), let id = infoPlist(url)?["CFBundleIdentifier"] as? String, !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }
}
