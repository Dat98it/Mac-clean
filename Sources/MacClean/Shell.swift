import AppKit
import Combine
import MacCleanCore
import SwiftUI

// The window's frame: a sidebar that says what Mac Clean can do, and one content area that shows the
// page picked there. The disk explorer stays AppKit (a million rows need NSOutlineView); the
// uninstaller pages are SwiftUI. No `@State` here either (see SettingsAndSuggestions.swift).

enum Page: Int, Hashable, CaseIterable {
    case disk, uninstall, leftovers

    var title: String {
        switch self {
        case .disk: L("Disk Explorer")
        case .uninstall: L("Uninstall Apps")
        case .leftovers: L("Leftover Data")
        }
    }

    /// The name used by the `--page` launch option.
    static func named(_ name: String) -> Page? {
        switch name {
        case "disk": .disk
        case "uninstall": .uninstall
        case "leftovers": .leftovers
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .disk: "internaldrive"
        case .uninstall: "xmark.bin"
        case .leftovers: "archivebox"
        }
    }
}

/// Which page is showing, plus the little the sidebar needs to know about the startup disk.
@MainActor
final class Navigation: ObservableObject {
    @Published var page: Page = .disk
    @Published var startup: Volume?
    var onSuggestions: (() -> Void)?
    var onSettings: (() -> Void)?
}

struct SidebarView: View {
    @ObservedObject var nav: Navigation

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<Page?>(get: { nav.page }, set: { if let page = $0 { nav.page = page } })) {
                Section(L("Storage")) {
                    SidebarRow(page: .disk)
                }
                Section(L("Apps")) {
                    SidebarRow(page: .uninstall)
                    SidebarRow(page: .leftovers)
                }
                Section(L("Tools")) {
                    Button { nav.onSuggestions?() } label: {
                        Label(L("Cleanup Suggestions"), systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .help(L("Safe things to clean, with a reason for each. Nothing is ticked for you."))
                    Button { nav.onSettings?() } label: {
                        Label(L("Settings"), systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            if let volume = nav.startup, volume.totalBytes > 0 { StartupMeter(volume: volume) }
        }
    }
}

struct SidebarRow: View {
    var page: Page

    var body: some View {
        Label(page.title, systemImage: page.symbol).tag(page)
    }
}

/// Free space of the startup disk, always in view: the number most people open a cleaner for.
struct StartupMeter: View {
    var volume: Volume

    var body: some View {
        let used = Double(volume.totalBytes - min(volume.availableBytes, volume.totalBytes))
        let freeShare = Double(volume.availableBytes) / Double(volume.totalBytes)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                Text(volume.name).font(.caption.weight(.medium)).lineLimit(1)
            }
            ProgressView(value: used, total: Double(volume.totalBytes)).tint(freeShare < 0.1 ? .red : freeShare < 0.2 ? .orange : .accentColor)
            Text(LF("%@ free of %@", Format.bytes(volume.availableBytes), Format.bytes(volume.totalBytes)))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}

/// Holds the disk explorer view and the uninstaller host; shows one of them.
@MainActor
final class PageContainerController: NSViewController {
    private let explorer: NSView
    private let uninstall: NSView

    init(explorer: NSView, uninstall: NSView) {
        self.explorer = explorer
        self.uninstall = uninstall
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        for child in [explorer, uninstall] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                child.topAnchor.constraint(equalTo: root.topAnchor),
                child.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        show(.disk)
    }

    func show(_ page: Page) {
        explorer.isHidden = page != .disk
        uninstall.isHidden = page == .disk
    }

    /// Called after every layout of the content area (the explorer sizes its columns to the new width).
    var onLayout: (() -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onLayout?() }
        }
    }
}

/// Sidebar on the left, pages on the right.
@MainActor
final class ShellViewController: NSSplitViewController {
    let container: PageContainerController

    init(navigation: Navigation, explorer: NSView, uninstall: NSView) {
        container = PageContainerController(explorer: explorer, uninstall: uninstall)
        super.init(nibName: nil, bundle: nil)
        let sidebarController = NSHostingController(rootView: SidebarView(nav: navigation))
        sidebarController.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 260
        sidebar.canCollapse = true
        addSplitViewItem(sidebar)
        let content = NSSplitViewItem(viewController: container)
        content.minimumThickness = 720
        addSplitViewItem(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
