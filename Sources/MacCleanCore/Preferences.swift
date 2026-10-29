import Foundation

/// Where settings are kept. `UserDefaults` in the app, a dictionary in tests.
public protocol PreferenceStoring: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

/// The user's settings, with their defaults.
public final class Preferences {
    let store: PreferenceStoring

    public init(store: PreferenceStoring) {
        self.store = store
    }

    static let showDockIconKey = "showDockIcon"
    static let allowlistKey = "allowlist"

    /// Shown by default. Hiding it keeps the menu bar icon, which always opens the window.
    public var showDockIcon: Bool {
        get { store.object(forKey: Self.showDockIconKey) as? Bool ?? true }
        set { store.set(newValue, forKey: Self.showDockIconKey) }
    }

    /// Extra folders whose contents may be moved to the Trash (validated when added).
    public var allowlist: [String] {
        get { store.object(forKey: Self.allowlistKey) as? [String] ?? [] }
        set { store.set(newValue, forKey: Self.allowlistKey) }
    }
}

/// How the app shows itself, derived from the settings. Kept apart so the rule is tested.
public enum Presence {
    public enum ActivationPolicy: Equatable { case regular, accessory }

    public static func activationPolicy(showDockIcon: Bool) -> ActivationPolicy {
        showDockIcon ? .regular : .accessory
    }
}

public enum TrashLocation {
    /// The Trash a volume's items go to: ~/.Trash on the startup disk, /Volumes/X/.Trashes/<uid> elsewhere.
    public static func folder(forMountPoint mountPoint: String, home: String, userID: UInt32) -> String {
        mountPoint == "/" ? home + "/.Trash" : mountPoint + "/.Trashes/" + String(userID)
    }
}
