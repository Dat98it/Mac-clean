import AppKit

/// The "Uninstall Mac Clean…" menu item: moves the app and its own files to the Trash.
@MainActor
final class SelfUninstaller {
    static let expectedBundleIdentifier = "com.dat98it.MacClean"

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    enum Outcome: Equatable {
        case removed(warnings: [String])
        case failed(String)
    }

    let bundleURL: URL
    let bundleIdentifier: String?
    let supportFolder: String
    private let loginItem: LoginItemService
    private let trash: (URL) throws -> Void

    init(bundleURL: URL = Bundle.main.bundleURL, bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         loginItem: LoginItemService, supportFolder: String,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.loginItem = loginItem
        self.supportFolder = supportFolder
        self.trash = trash
    }

    var availability: Availability {
        // A `swift run` build has a folder of binaries as its "bundle": never move that.
        guard bundleURL.pathExtension == "app" else {
            return .unavailable(L("This copy is not an installed app (it looks like a development build)."))
        }
        guard bundleIdentifier == Self.expectedBundleIdentifier else {
            return .unavailable(L("This app does not look like Mac Clean, so it will not be removed."))
        }
        guard !((try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false) else {
            return .unavailable(L("Mac Clean is running from a read-only disk. Drag it into Applications first."))
        }
        guard FileManager.default.isDeletableFile(atPath: bundleURL.path) else {
            return .unavailable(L("This account is not allowed to remove Mac Clean from its current folder."))
        }
        return .available
    }

    var confirmationText: String {
        String(format: L("Mac Clean will quit and move to the Trash: itself (%@), its settings, its action log and its list of ignored items. Launch at Login is turned off. Until you empty the Trash you can put it back."),
               (bundleURL.path as NSString).abbreviatingWithTildeInPath)
    }

    func uninstall() -> Outcome {
        if case .unavailable(let reason) = availability { return .failed(reason) }
        var warnings: [String] = []
        let loginWasOn = loginItem.status == .enabled || loginItem.status == .requiresApproval
        if loginWasOn {
            do { try loginItem.unregister() } catch {
                warnings.append(L("Couldn't turn off Launch at Login. Remove it in System Settings → General → Login Items."))
            }
        }
        do {
            try trash(bundleURL)
        } catch {
            if loginWasOn { try? loginItem.register() }
            return .failed(error.localizedDescription)
        }
        if FileManager.default.fileExists(atPath: supportFolder) {
            do { try trash(URL(fileURLWithPath: supportFolder)) } catch { warnings.append(error.localizedDescription) }
        }
        UserDefaults.standard.removePersistentDomain(forName: Self.expectedBundleIdentifier)
        return .removed(warnings: warnings)
    }
}
