import SwiftUI
import UniformTypeIdentifiers
import UninstallCore
import UninstallSystem

// Adapted from App Clean's Views.swift, redesigned for the Mac Clean window: one visual language
// (header, cards, footer bar) shared with the sidebar pages.
//
// No `@State` anywhere: with only the Command Line Tools its macro plugin is missing, so all view
// state lives in `UninstallModel` (an ObservableObject).

// MARK: - Shared pieces

/// The title block every page starts with: an icon tile, a title, one line of explanation, and
/// whatever the page wants on its right (a button, a total).
struct PageHeader<Trailing: View>: View {
    var symbol: String
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// A rounded, softly filled panel for notices and empty states.
struct Card<Content: View>: View {
    var tint: Color = .secondary
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.18)))
    }
}

struct PermissionBanner: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        Card(tint: .orange) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Full Disk Access is off")).font(.headline)
                    Text(L("Some folders (app containers, cookies) can't be read, so their contents are skipped and sizes are lower than real. In System Settings → Privacy & Security → Full Disk Access, click +, choose Mac Clean in Applications and switch it on. Then quit and reopen Mac Clean: macOS applies it when the app starts."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !model.unreadable.isEmpty {
                        Text(String(format: L("Skipped: %@"), model.unreadable.map(shortPath).joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Button(L("Open Settings")) { Permissions.openFullDiskAccessSettings() }
                    if model.canRelaunch {
                        Button(L("Quit and Reopen")) { model.relaunch() }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

struct MessageBar: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        Card(tint: .accentColor) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
                Text(text).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("OK"), action: dismiss)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Page host

/// Everything the uninstaller shows. The sidebar decides which of the two pages (`model.mode`) is up.
struct UninstallRootView: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.mode {
                case .uninstall: UninstallView(model: model)
                case .leftovers: LeftoversView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let report = model.report {
                ReportBar(model: model, report: report)
            } else if !model.visibleGroups.isEmpty {
                FooterBar(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: Binding(get: { model.confirmation }, set: { model.confirmation = $0 })) { confirmation in
            ConfirmView(model: model, confirmation: confirmation)
        }
    }
}

/// Banners that sit above a page's content.
struct PageNotices: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess { PermissionBanner(model: model) }
            if let message = model.message { MessageBar(text: message) { model.message = nil } }
        }
    }
}

// MARK: - Uninstall page

struct UninstallView: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        VStack(spacing: 0) {
            if let target = model.target {
                PageHeader(symbol: "xmark.bin.fill", title: Page.uninstall.title,
                           subtitle: L("Review everything this app owns, then move it to the Trash.")) {
                    Button(L("Choose another app…")) { chooseApp(model) }
                }
                Divider()
                PageNotices(model: model).padding(.top, 8)
                TargetHeader(model: model, target: target)
                Divider()
                if model.scanning {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L("Looking for files that belong to this app…")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.uninstallGroups.isEmpty {
                    FinishedState(model: model)
                } else {
                    GroupedList(model: model, groups: model.uninstallGroups)
                }
            } else {
                PageHeader(symbol: "xmark.bin.fill", title: Page.uninstall.title,
                           subtitle: L("Remove an app together with everything it leaves behind.")) { EmptyView() }
                Divider()
                PageNotices(model: model).padding(.top, 8)
                DropBox(model: model)
            }
        }
    }
}

/// The app being removed: icon, name, identifier, and what was found.
struct TargetHeader: View {
    @ObservedObject var model: UninstallModel
    var target: AppIdentity

    var body: some View {
        HStack(spacing: 14) {
            // Changed your mind: back to the drop box, nothing is removed.
            Button { model.clearTarget() } label: {
                Image(systemName: "chevron.backward").font(.title3.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help(L("Back to the drop box (Esc). Nothing is removed."))
            .accessibilityLabel(L("Back"))
            Image(nsImage: NSWorkspace.shared.icon(forFile: target.path)).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.names.first ?? Paths.lastComponent(target.path)).font(.title3.weight(.semibold))
                Text(target.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if !model.scanning && !model.findings.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.sizing && model.foundBytes == 0 ? "…" : UninstallModel.bytes(model.foundBytes))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text(String(format: L("%d items found"), model.findings.count)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

@MainActor
func chooseApp(_ model: UninstallModel) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.canChooseDirectories = false
    panel.treatsFilePackagesAsDirectories = false
    if panel.runModal() == .OK, let url = panel.url { model.open(url) }
}

/// What the uninstall page shows when no rows are left: either everything was just removed, or
/// nothing was found for the app in the first place.
struct FinishedState: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        let removed = model.report != nil
        VStack(spacing: 12) {
            Image(systemName: removed ? "checkmark.circle.fill" : "questionmark.folder.fill")
                .font(.system(size: 52)).foregroundStyle(removed ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(removed ? L("Cleanup finished") : L("Nothing found for this app")).font(.title.weight(.semibold))
            Text(removed ? L("Nothing is left to remove for this app.") : L("No files in your Library match this app."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(L("Choose another app…")) { chooseApp(model) }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DropBox: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(model.dropTargeted ? 0.22 : 0.12)).frame(width: 96, height: 96)
                Image(systemName: model.dropTargeted ? "arrow.down.app.fill" : "arrow.down.app")
                    .font(.system(size: 42, weight: .light)).foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(L("Drop an app here")).font(.title.weight(.semibold))
                Text(L("or onto the Mac Clean icon in the menu bar. Nothing is removed until you confirm."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Button(L("Choose an app…")) { chooseApp(model) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Divider().padding(.horizontal, 40).padding(.vertical, 4)
            HStack(alignment: .top, spacing: 18) {
                Step(number: 1, title: L("Drop an app"), detail: L("Any app from Applications."))
                Step(number: 2, title: L("Review the list"), detail: L("Only the safe items are ticked."))
                Step(number: 3, title: L("Move to the Trash"), detail: L("You can put everything back."))
            }
        }
        .padding(32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(model.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(model.dropTargeted ? Color.accentColor.opacity(0.07) : Color.clear))
                .padding(20)
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { model.dropTargeted }, set: { model.dropTargeted = $0 })) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                // Drags may carry a file reference URL (file:///.file/id=…); turn it into a path URL.
                let fileURL = (url as NSURL).filePathURL ?? url
                Task { @MainActor in model.open(fileURL) }
            }
            return true
        }
    }
}

struct Step: View {
    var number: Int
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Color.secondary))
            Text(title).font(.callout.weight(.medium)).multilineTextAlignment(.center)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Leftovers page

struct LeftoversView: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "archivebox.fill", title: Page.leftovers.title,
                       subtitle: L("Find data left behind by apps that are no longer on this Mac.")) {
                if model.orphanScanning {
                    Button(L("Stop")) { model.cancelScan() }.controlSize(.large)
                } else {
                    Button { model.scanLeftovers() } label: {
                        Label(model.orphans == nil ? L("Scan") : L("Scan again"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            Divider()
            PageNotices(model: model).padding(.top, 8)
            if model.orphans != nil && !model.orphanScanning { filterBar }
            content
        }
    }

    private var filterBar: some View {
        HStack(spacing: 14) {
            TextField(L("Filter by name"), text: Binding(get: { model.filter }, set: { model.filter = $0 }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            Toggle(L("Show uncertain"), isOn: Binding(get: { model.showUncertain }, set: { model.showUncertain = $0 }))
                .help(L("Data of a developer that still has another app installed. It may be shared."))
            Toggle(L("Show unknown owner"), isOn: Binding(get: { model.showUnknown }, set: { model.showUnknown = $0 }))
                .help(L("Folders named without an app identifier that no installed app or tool claims."))
            Spacer()
            if !model.leftoverGroups.isEmpty {
                Text(String(format: L("%d old apps · %@"), model.leftoverGroups.count, UninstallModel.bytes(model.leftoverBytes)))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if model.orphanScanning {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(L("Looking through ~/Library…")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.orphans == nil {
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 96, height: 96)
                    Image(systemName: "magnifyingglass").font(.system(size: 40, weight: .light)).foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)
                Text(L("Ready when you are")).font(.title.weight(.semibold))
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("Looks only at your ~/Library, never at your documents."), systemImage: "eye")
                    Label(L("Nothing is ticked for you: look at each item and choose."), systemImage: "checkmark.circle")
                    Label(L("Everything goes to the Trash, so you can put it back."), systemImage: "arrow.uturn.backward")
                }
                .font(.callout).foregroundStyle(.secondary)
                if model.ignoredCount > 0 {
                    Button(String(format: L("Suggest the %d ignored items again"), model.ignoredCount)) { model.clearIgnoreList() }
                        .buttonStyle(.link)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.leftoverGroups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text(L("No leftovers found.")).font(.title3.weight(.semibold))
                Text(L("Nothing from removed apps is taking up space.")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GroupedList(model: model, groups: model.leftoverGroups)
        }
    }
}

// MARK: - The list

struct GroupedList: View {
    @ObservedObject var model: UninstallModel
    var groups: [RowGroup]

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in RowView(model: model, row: row) }
                } header: {
                    GroupHeader(model: model, group: group)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
    }
}

struct GroupHeader: View {
    @ObservedObject var model: UninstallModel
    var group: RowGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { model.toggle(group) } label: {
                    Image(systemName: symbol).font(.title3)
                        .foregroundStyle(model.state(of: group) == .none ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(L("Tick or untick the whole group"))
                .accessibilityLabel(L("Tick or untick the whole group"))
                Text(group.title).font(.headline).textSelection(.enabled)
                Text("\(group.rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.secondary.opacity(0.15)))
                if let subtitle = group.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(UninstallModel.bytes(model.total(group))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if group.canIgnore {
                    Button(L("Don't suggest again")) { model.ignore(group) }.buttonStyle(.link).font(.caption)
                }
            }
            if let warning = group.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }

    var symbol: String {
        switch model.state(of: group) {
        case .none: "square"
        case .some: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }
}

struct RowView: View {
    @ObservedObject var model: UninstallModel
    var row: Row

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.isSelected(row.path) }, set: { model.setSelected(row.path, $0) }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(systemName: Self.symbol(for: row.kind)).font(.callout).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(Paths.lastComponent(row.path)).lineLimit(1).truncationMode(.middle)
                    ConfidenceBadge(confidence: row.confidence)
                    if row.domain == .system {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help(L("Needs an administrator password"))
                    }
                    if row.kind.mayHoldUserData {
                        Image(systemName: "person.crop.square").font(.caption).foregroundStyle(.orange)
                            .help(L("May contain your own data (documents, saves, databases, licences)."))
                    }
                }
                Text(shortPath(row.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if !row.reason.isEmpty { Text(row.reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.sizes[row.path].map(UninstallModel.bytes) ?? (model.sizing ? "…" : "—")).font(.callout.monospacedDigit())
                Text(UninstallModel.date(model.modified[row.path] ?? row.modified ?? .distantPast)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(L("Show in Finder")) { NSWorkspace.shared.selectFile(row.path, inFileViewerRootedAtPath: "") }
            Button(L("Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.path, forType: .string)
            }
        }
    }

    static func symbol(for kind: DataKind) -> String {
        switch kind {
        case .appBundle: "macwindow"
        case .cache: "tray.full"
        case .log: "doc.text"
        case .preferences: "gearshape"
        case .savedState: "clock.arrow.circlepath"
        case .webData: "globe"
        case .userData: "folder"
        case .launchItem: "bolt"
        case .helper: "wrench.and.screwdriver"
        case .receipt: "shippingbox"
        case .scripts: "scroll"
        }
    }
}

struct ConfidenceBadge: View {
    var confidence: Confidence

    var body: some View {
        Text(label).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
            .help(help)
    }

    var label: String {
        switch confidence {
        case .high: L("sure")
        case .medium: L("likely")
        case .low: L("unsure")
        }
    }

    var color: Color {
        switch confidence {
        case .high: .green
        case .medium: .blue
        case .low: .orange
        }
    }

    var help: String {
        switch confidence {
        case .high: L("Named after the app's identifier.")
        case .medium: L("Named after the app, or from the same developer.")
        case .low: L("Only the name looks related. Check before removing.")
        }
    }
}

func shortPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

// MARK: - Footer, confirmation, result

struct FooterBar: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                let count = model.selectedVisiblePaths.count
                VStack(alignment: .leading, spacing: 1) {
                    Text(count == 0 ? L("Nothing selected") : String(format: L("%d selected"), count)).font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        Text(UninstallModel.bytes(model.selectedBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if model.sizing { ProgressView().controlSize(.mini) }
                    }
                }
                Button(L("Select All")) { model.selectAllVisible() }.buttonStyle(.link)
                Button(L("Clear")) { model.clearSelection() }.buttonStyle(.link).disabled(count == 0)
                Spacer()
                Button { model.requestRemoval() } label: {
                    Label(L("Move to Trash…"), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(count == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

struct ConfirmView: View {
    @ObservedObject var model: UninstallModel
    var confirmation: Confirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let plan = confirmation.plan
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("Move %d items (%@) to the Trash?"), plan.items.count, UninstallModel.bytes(plan.totalBytes)))
                        .font(.title3.weight(.semibold))
                    Text(L("You can put them back from the Trash. Disk space is only freed when the Trash is emptied."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !confirmation.runningApps.isEmpty {
                Card(tint: .red) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("The app is running. Quit it first, then check again."), systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                        HStack {
                            Button(L("Quit the app")) { model.quitRunningApps() }
                            Button(L("Check again")) { model.recheckRunning() }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if confirmation.userDataCount > 0 {
                    Label(String(format: L("%d items may contain your own data (documents, saves, databases, licences)."), confirmation.userDataCount),
                          systemImage: "person.crop.square").foregroundStyle(.orange)
                }
                if !plan.adminItems.isEmpty {
                    Label(String(format: L("%d items are system-wide: macOS will ask for an administrator password."), plan.adminItems.count),
                          systemImage: "lock")
                }
                if confirmation.launchAgentCount > 0 {
                    Label(L("Launch items are stopped before they are moved."), systemImage: "bolt.slash")
                }
                if !plan.rejected.isEmpty {
                    Label(String(format: L("%d ticked items are protected and will be left alone."), plan.rejected.count),
                          systemImage: "shield").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.items, id: \.displayPath) { item in
                        HStack {
                            Text(shortPath(item.displayPath)).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(UninstallModel.bytes(item.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 80, maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
            HStack {
                Spacer()
                Button(L("Cancel")) { model.confirmation = nil }.keyboardShortcut(.cancelAction)
                Button(L("Move to Trash")) { model.performConfirmed() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!confirmation.runningApps.isEmpty || plan.items.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}

struct ReportBar: View {
    @ObservedObject var model: UninstallModel
    var report: ActionReport

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: report.deletedPermanently != nil ? "checkmark.circle.fill" : "trash.circle.fill")
                        .font(.title).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        if let deleted = report.deletedPermanently {
                            Text(String(format: L("Deleted %d items permanently, about %@ freed."), deleted.count,
                                        UninstallModel.bytes(deleted.reduce(0) { $0 + $1.bytes })))
                                .font(.callout.weight(.medium))
                        } else {
                            Text(String(format: L("Moved %d items (%@) to the Trash. The space is freed when you empty the Trash."),
                                        report.trashed.count, UninstallModel.bytes(report.trashedBytes)))
                                .font(.callout.weight(.medium))
                            if report.receiptsForgotten > 0 {
                                Text(String(format: L("%d installer receipts forgotten."), report.receiptsForgotten))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if report.deletedPermanently == nil && !report.trashed.isEmpty {
                        Button(String(format: L("Delete these %d permanently…"), report.trashed.count)) { confirmPermanent() }
                    }
                    Button(L("Done")) {
                        model.report = nil
                        if model.mode == .uninstall && model.findings.allSatisfy({ $0.kind != .appBundle }) { model.clearTarget() }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
                ForEach(Array((report.problems + report.permanentProblems).prefix(6).enumerated()), id: \.offset) { _, p in
                    Text("• \(shortPath(p.path)): \(p.message)").font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    @MainActor
    func confirmPermanent() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(format: L("Delete %d items permanently?"), report.trashed.count)
        var text = L("Only the items Mac Clean just moved to the Trash are deleted; nothing else in the Trash is touched. This can't be undone.")
        let adminCount = model.permanentAdminCount
        if adminCount > 0 {
            text += "\n\n" + String(format: L("%d items belong to the system: macOS will ask for an administrator password."), adminCount)
        }
        alert.informativeText = text
        alert.addButton(withTitle: L("Delete Permanently"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        // Return must not delete: make Cancel the default button.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn { model.deletePermanently() }
    }
}
