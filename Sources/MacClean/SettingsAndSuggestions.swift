import AppKit
import MacCleanCore
import MacCleanSystem
import SwiftUI

// No `@State` here: the Command Line Tools have no macro plugin for it. State lives in
// ObservableObjects and bindings are written by hand with Binding(get:set:).

@MainActor
final class SettingsModel: ObservableObject {
    weak var delegate: AppDelegate?
    init(delegate: AppDelegate) { self.delegate = delegate }

    var showDockIcon: Bool { delegate?.prefs.showDockIcon ?? true }
    var launchAtLogin: Bool { delegate?.launchAtLogin.menuState == .on }
    var allowlist: [String] { delegate?.prefs.allowlist ?? [] }
    var hasFullDiskAccess: Bool { delegate?.model.hasFullDiskAccess ?? false }
    var home: String { delegate?.env.home ?? "~" }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(L("Show Icon in Dock"), isOn: Binding(get: { model.showDockIcon }, set: { model.delegate?.setShowDockIcon($0) }))
                Text(L("When the Dock icon is hidden, open Mac Clean from its icon in the menu bar."))
                    .font(.caption).foregroundColor(.secondary)
                Toggle(L("Launch at Login"), isOn: Binding(get: { model.launchAtLogin }, set: { _ in model.delegate?.toggleLaunchAtLogin() }))
            }
            Section(L("Where Mac Clean may move items to the Trash")) {
                Text(LF("Your home folder (%@), external disks, and the folders below. System folders, /Library, Keychains, Mail, Messages and Photos libraries can only be viewed.", model.home))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(model.allowlist, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L("Remove")) { model.delegate?.removeAllowlistFolder(path) }
                    }
                }
                Button(L("Allow a Folder…")) { model.delegate?.addAllowlistFolder() }
            }
            Section(L("Full Disk Access")) {
                Text(model.hasFullDiskAccess ? L("Mac Clean has Full Disk Access.")
                     : L("Without Full Disk Access, Desktop, Documents, Mail and other apps' data are left out of the scan."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Open Privacy Settings…")) { Permissions.openFullDiskAccessSettings() }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
    }
}

/// Suggestions with a tick box per item, all unticked to begin with.
@MainActor
final class SuggestionsModel: ObservableObject {
    @Published var suggestions: [Suggestion]
    let onTick: ([NodeID]) -> Void

    init(suggestions: [Suggestion], onTick: @escaping ([NodeID]) -> Void) {
        self.suggestions = suggestions
        self.onTick = onTick
    }

    func binding(_ s: Int, _ i: Int) -> Binding<Bool> {
        Binding(get: { self.suggestions[s].items[i].isSelected }, set: { self.suggestions[s].items[i].isSelected = $0 })
    }

    var picked: [NodeID] { suggestions.flatMap { $0.items.filter(\.isSelected).map(\.node) } }
}

struct SuggestionsView: View {
    @ObservedObject var model: SuggestionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.suggestions.isEmpty {
                Text(L("No suggestions. Scan the startup disk first, or there is nothing typical to clean."))
                    .foregroundColor(.secondary).padding()
                Spacer()
            } else {
                Text(L("Nothing is ticked for you. Read why each group is usually safe, then tick what you want; the items are ticked in the main window, where you move them to the Trash."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                List {
                    ForEach(model.suggestions.indices, id: \.self) { s in
                        let suggestion = model.suggestions[s]
                        Section {
                            Text(L(suggestion.explanation)).font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(suggestion.items.indices, id: \.self) { i in
                                Toggle(isOn: model.binding(s, i)) {
                                    HStack {
                                        Text(suggestion.items[i].path).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(Format.bytes(suggestion.items[i].bytes)).monospacedDigit().foregroundColor(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text(L(suggestion.title) + " — " + Format.bytes(suggestion.totalBytes))
                        }
                    }
                }
            }
            HStack {
                Text(LF("%@ items picked", Format.count(model.picked.count))).foregroundColor(.secondary)
                Spacer()
                Button(L("Tick in Main Window")) { model.onTick(model.picked) }
                    .disabled(model.picked.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 440)
    }
}
