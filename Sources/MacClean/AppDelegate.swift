import AppKit
import MacCleanCore
import MacCleanSystem
import SwiftUI

/// The menu bar icon and its menu, the Dock icon setting, the main menu, and the windows.
///
/// The app always has a menu bar icon, whose menu always opens the window: hiding the Dock icon
/// never leaves the user without a way back. Closing the window keeps the app running; only Quit ends it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let env: MacCleanEnvironment
    let prefs: Preferences
    let model: AppModel
    let launchAtLogin = LaunchAtLogin(service: SystemLoginItemService())
    private var statusItem: NSStatusItem!
    private var windowController: MainWindowController?
    private var settingsWindow: NSWindow?
    private var suggestionsWindow: NSWindow?
    private lazy var settingsModel = SettingsModel(delegate: self)

    init(env: MacCleanEnvironment, prefs: Preferences) {
        self.env = env
        self.prefs = prefs
        model = AppModel(env: env, prefs: prefs)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(target: self)
        // The glyph (a drive being swept) is a bit wider than tall, so the item takes the glyph's width.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarGlyph()
        statusItem.button?.toolTip = "Mac Clean"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        applyDockIcon(prefs.showDockIcon, bringWindowForward: false)

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refreshVolumes() }
            }
        }
        // A disk about to go away: stop reading it at once, so ejecting is not held up.
        center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated {
                guard let self, let path, let session = self.model.sessions[path] else { return }
                session.cancelFlag.cancel()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshPermissions() }
        }

        // Opened at login: stay in the menu bar. Otherwise show the window.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin || CommandLine.arguments.contains("--show") { showWindow() }
    }

    /// Resources/MenuBarIcon.png and @2x (made by Scripts/make_menubar_icon.swift), as a template
    /// so macOS tints it for light and dark menu bars. Outside an app bundle (swift run), a system symbol.
    static func menuBarGlyph() -> NSImage? {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = "Mac Clean"
        return image
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon, or opening the app again from Finder or Spotlight, shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: Window

    @objc func showWindow() {
        if windowController == nil {
            let controller = MainWindowController(model: model)
            controller.onOpenSuggestions = { [weak self] in self?.showSuggestions() }
            controller.onOpenSettings = { [weak self] in self?.showSettings() }
            windowController = controller
        }
        windowController?.showWindow(nil)
        if let window = windowController?.window { Self.bringForward(window) }
        windowController?.scanIfNeeded()
    }

    @objc func rescan() {
        showWindow()
        if let volume = model.selectedVolume, model.volumes.contains(where: { $0.id == volume.id }) { model.scan(volume) }
    }

    // MARK: Dock icon

    /// Shows or hides the Dock icon at once. When hiding, the app becomes a menu bar app; macOS
    /// deactivates it, so it is activated again and its window brought forward if one was open.
    func applyDockIcon(_ show: Bool, bringWindowForward: Bool) {
        let wanted: NSApplication.ActivationPolicy = Presence.activationPolicy(showDockIcon: show) == .regular ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
        guard bringWindowForward else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let window = self?.windowController?.window, window.isVisible { Self.bringForward(window) }
                if let window = self?.settingsWindow, window.isVisible { Self.bringForward(window) }
            }
        }
    }

    /// Activates the app and puts the window in front. Since macOS 14 activation may be refused
    /// right after the activation policy changed, so the window is also ordered front on its own:
    /// it is then visible even when the app could not become active.
    static func bringForward(_ window: NSWindow) {
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func setShowDockIcon(_ show: Bool) {
        prefs.showDockIcon = show
        applyDockIcon(show, bringWindowForward: true)
        settingsModel.objectWillChange.send()
    }

    @objc func toggleDockIcon() {
        setShowDockIcon(!prefs.showDockIcon)
        if !prefs.showDockIcon { showWindow() }
    }

    // MARK: Menu bar menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Mac Clean" + (env.isSandbox ? " (sandbox)" : ""), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for volume in model.volumes {
            let item = NSMenuItem(title: volume.availableBytes > 0 ? LF("%@: %@ free", volume.name, Format.bytes(volume.availableBytes)) : volume.name,
                                  action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: volume.kind == .startupData ? "internaldrive" : "externaldrive", accessibilityDescription: nil)
            item.isEnabled = false
            menu.addItem(item)
        }
        let status = NSMenuItem(title: scanStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Open Mac Clean Window"), action: #selector(showWindow), keyEquivalent: "").target = self
        let rescan = menu.addItem(withTitle: model.anyScanning ? L("Stop Scanning") : L("Scan Again"),
                                  action: model.anyScanning ? #selector(stopScanning) : #selector(rescan), keyEquivalent: "")
        rescan.target = self
        menu.addItem(.separator())
        let dock = menu.addItem(withTitle: L("Show Icon in Dock"), action: #selector(toggleDockIcon), keyEquivalent: "")
        dock.target = self
        dock.state = prefs.showDockIcon ? .on : .off
        let login = menu.addItem(withTitle: L("Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = launchAtLogin.menuState
        menu.addItem(withTitle: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("Show Action Log"), action: #selector(showLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit Mac Clean"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private var scanStatus: String {
        if let scanning = model.sessions.values.first(where: { $0.isScanning }) {
            return LF("Scanning %@: %@ items…", scanning.volume.name, Format.count(scanning.store.count))
        }
        if let last = model.sessions.values.compactMap(\.finishedAt).max() {
            return LF("Last scan: %@", Format.date.string(from: last))
        }
        return L("Not scanned yet.")
    }

    @objc func stopScanning() {
        for session in model.sessions.values { session.cancelFlag.cancel() }
    }

    @objc func toggleLaunchAtLogin() {
        if case .failed(let message) = launchAtLogin.toggle() {
            let alert = NSAlert()
            alert.messageText = L("Launch at Login could not be changed")
            alert.informativeText = message
            alert.runModal()
        }
        settingsModel.objectWillChange.send()
    }

    @objc func showLog() {
        if FileManager.default.fileExists(atPath: env.logFile) {
            NSWorkspace.shared.selectFile(env.logFile, inFileViewerRootedAtPath: "")
        } else {
            let alert = NSAlert()
            alert.messageText = L("Nothing has been moved yet")
            alert.informativeText = L("The log lists everything Mac Clean moves to the Trash or deletes.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Settings and suggestions

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = L("Mac Clean Settings")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: settingsModel))
            window.center()
            settingsWindow = window
        }
        if let window = settingsWindow { Self.bringForward(window) }
    }

    func showSuggestions() {
        let suggestions = model.suggestions()
        let suggestionModel = SuggestionsModel(suggestions: suggestions) { [weak self] picked in
            self?.suggestionsWindow?.close()
            self?.tickSuggested(picked)
        }
        let window = suggestionsWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L("Cleanup Suggestions")
            w.isReleasedWhenClosed = false
            w.center()
            return w
        }()
        window.contentView = NSHostingView(rootView: SuggestionsView(model: suggestionModel))
        suggestionsWindow = window
        Self.bringForward(window)
    }

    /// Ticks, in the startup disk's tree, the suggested items the user picked, and shows that tree.
    private func tickSuggested(_ nodes: [NodeID]) {
        guard let session = model.startupSession else { return }
        model.selectedVolumeID = session.volume.id
        var refused: [String] = []
        for id in nodes where session.store.isInTree(id) && model.tickedAncestor(of: id, in: session) == nil {
            if let reason = model.toggleTick(id) { refused.append(session.store.path(id) + ": " + R(reason)) }
        }
        model.onStateChanged?()
        model.onTreeChanged?([])
        showWindow()
        if !refused.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("Some suggested items cannot be moved")
            alert.informativeText = refused.prefix(10).joined(separator: "\n")
            alert.runModal()
        }
    }

    func addAllowlistFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Allow")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if case .denied(let reason) = model.policy.canAllowlist(path) {
            let alert = NSAlert()
            alert.messageText = L("This folder cannot be allowed")
            alert.informativeText = path + "\n" + R(reason)
            alert.runModal()
            return
        }
        if !prefs.allowlist.contains(path) { prefs.allowlist.append(path) }
        model.sessions.values.forEach { $0.verdicts.removeAll() }
        settingsModel.objectWillChange.send()
    }

    func removeAllowlistFolder(_ path: String) {
        prefs.allowlist.removeAll { $0 == path }
        model.sessions.values.forEach { $0.verdicts.removeAll() }
        // Ticks that are no longer allowed are dropped.
        for session in model.sessions.values {
            session.ticked = session.ticked.filter { model.verdict($0, in: session).isAllowed }
        }
        model.onTreeChanged?([])
        settingsModel.objectWillChange.send()
    }
}

/// The main menu. It stays installed when the Dock icon is hidden: it is not shown then, but its
/// key equivalents (Cmd+C, V, A, W, Q...) keep working in the windows.
enum MainMenu {
    @MainActor
    static func make(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "Mac Clean", action: nil, keyEquivalent: "")
        let app = NSMenu(title: "Mac Clean")
        app.addItem(withTitle: L("About Mac Clean"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Settings…"), action: #selector(AppDelegate.showSettings), keyEquivalent: ",").target = target
        app.addItem(.separator())
        app.addItem(withTitle: L("Hide Mac Clean"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: L("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Quit Mac Clean"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let fileItem = main.addItem(withTitle: L("File"), action: nil, keyEquivalent: "")
        let file = NSMenu(title: L("File"))
        file.addItem(withTitle: L("Open Mac Clean Window"), action: #selector(AppDelegate.showWindow), keyEquivalent: "n").target = target
        file.addItem(withTitle: L("Scan Again"), action: #selector(AppDelegate.rescan), keyEquivalent: "r").target = target
        file.addItem(.separator())
        file.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = main.addItem(withTitle: L("Edit"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = main.addItem(withTitle: L("Window"), action: nil, keyEquivalent: "")
        let window = NSMenu(title: L("Window"))
        window.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: L("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = window
        NSApp.windowsMenu = window
        return main
    }
}
