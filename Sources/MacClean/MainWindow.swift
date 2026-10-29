import AppKit
import MacCleanCore
import MacCleanSystem
import Quartz
import UniformTypeIdentifiers

/// One row of the outline. NSOutlineView needs objects with a stable identity; one per node shown.
final class NodeItem: NSObject {
    let id: NodeID
    init(_ id: NodeID) { self.id = id }
}

/// The main window: volume picker, scan control, filters, the lazy tree, and the Trash button.
/// AppKit (NSOutlineView) because a million rows need it.
@MainActor
final class MainWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate,
    NSSearchFieldDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSMenuDelegate {
    let model: AppModel
    var onOpenSuggestions: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let volumePopup = NSPopUpButton()
    private let scanButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let sizePopup = NSPopUpButton()
    private let agePopup = NSPopUpButton()
    private let packagesCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsButton = NSButton()
    private let accessBanner = NSStackView()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    let outline = TreeOutlineView()
    private let selectionLabel = NSTextField(labelWithString: "")
    private let untickButton = NSButton()
    private let suggestionsButton = NSButton()
    private let trashButton = NSButton()

    private var items: [NodeID: NodeItem] = [:]
    private var childCache: [NodeID: [NodeID]] = [:]
    /// Flat list shown when a name or age filter is on.
    private var flatResults: [NodeID]?
    private var flatTruncated = false
    private var lastReload = Date.distantPast
    private var pendingTouched = Set<NodeID>()
    private var reloadScheduled = false
    private var shownSessionID: ObjectIdentifier?
    private var searchWork: DispatchWorkItem?
    private var searchGeneration = 0

    static let sizeSteps: [UInt64] = [0, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000]
    static let ageSteps: [Int?] = [nil, 30, 90, 365, 730]

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = model.env.isSandbox ? "Mac Clean (sandbox)" : "Mac Clean"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 420)
        super.init(window: window)
        window.delegate = self
        buildInterface()
        window.center()
        window.isRestorable = false
        // Sandbox runs write nothing outside the sandbox folder, so they remember no window frames.
        if !model.env.isSandbox { window.setFrameAutosaveName("MainWindow") }
        model.onTreeChanged = { [weak self] touched in self?.treeChanged(touched) }
        model.onStateChanged = { [weak self] in self?.stateChanged() }
        stateChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        volumePopup.target = self
        volumePopup.action = #selector(volumeChosen)
        scanButton.bezelStyle = .rounded
        scanButton.target = self
        scanButton.action = #selector(scanOrCancel)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [volumePopup, scanButton, spinner, statusLabel])
        topRow.spacing = 8

        searchField.placeholderString = L("Filter by name")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        sizePopup.addItems(withTitles: [L("Any size"), "≥ 1 MB", "≥ 10 MB", "≥ 100 MB", "≥ 1 GB"])
        sizePopup.target = self
        sizePopup.action = #selector(filterChanged)
        agePopup.addItems(withTitles: [L("Any age"), L("Unchanged for 30 days"), L("Unchanged for 90 days"),
                                       L("Unchanged for 1 year"), L("Unchanged for 2 years")])
        agePopup.target = self
        agePopup.action = #selector(filterChanged)
        packagesCheck.title = L("Show package contents")
        packagesCheck.target = self
        packagesCheck.action = #selector(packagesToggled)
        let filterRow = NSStackView(views: [searchField, sizePopup, agePopup, packagesCheck])
        filterRow.spacing = 8

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailsButton.title = L("Details…")
        detailsButton.bezelStyle = .inline
        detailsButton.target = self
        detailsButton.action = #selector(showDetails)
        let summaryRow = NSStackView(views: [summaryLabel, detailsButton])
        summaryRow.alignment = .firstBaseline

        let bannerText = NSTextField(wrappingLabelWithString: L("Mac Clean does not have Full Disk Access. Folders such as Desktop, Documents, Mail and other apps' data are left out of the scan so that macOS does not ask for permission again and again."))
        bannerText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bannerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bannerButton = NSButton(title: L("Open Privacy Settings…"), target: self, action: #selector(openPrivacy))
        accessBanner.setViews([NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)!), bannerText, bannerButton], in: .leading)
        accessBanner.spacing = 8
        accessBanner.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        accessBanner.wantsLayer = true
        accessBanner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        accessBanner.layer?.cornerRadius = 6

        noticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noticeLabel.textColor = .systemRed

        buildOutline()
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        selectionLabel.textColor = .secondaryLabelColor
        untickButton.title = L("Untick All")
        untickButton.bezelStyle = .rounded
        untickButton.target = self
        untickButton.action = #selector(untickAll)
        suggestionsButton.title = L("Cleanup Suggestions…")
        suggestionsButton.bezelStyle = .rounded
        suggestionsButton.target = self
        suggestionsButton.action = #selector(openSuggestions)
        trashButton.title = L("Move to Trash…")
        trashButton.bezelStyle = .rounded
        trashButton.keyEquivalent = ""
        trashButton.target = self
        trashButton.action = #selector(moveToTrash)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [selectionLabel, untickButton, spacer, suggestionsButton, trashButton])
        bottomRow.spacing = 8

        let stack = NSStackView(views: [topRow, filterRow, accessBanner, summaryRow, noticeLabel, scroll, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for row in [topRow, filterRow, accessBanner, summaryRow, noticeLabel, scroll, bottomRow] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func buildOutline() {
        let columns: [(String, String, CGFloat, SortColumn)] = [
            ("name", L("Name"), 380, .name), ("size", L("Size"), 100, .size), ("created", L("Date Created"), 150, .created),
            ("modified", L("Date Modified"), 150, .modified), ("kind", L("Kind"), 140, .kind),
        ]
        for (id, title, width, sort) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 220 : 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: sort == .name || sort == .kind)
            if id == "size" { column.headerCell.alignment = .right }
            outline.addTableColumn(column)
            if id == "name" { outline.outlineTableColumn = column }
        }
        // Only the last column follows the window width; the name column keeps its room.
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        if !model.env.isSandbox {
            outline.autosaveTableColumns = true
            outline.autosaveName = "TreeColumns"
        }
        outline.rowHeight = 20
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.sortDescriptors = [NSSortDescriptor(key: SortColumn.size.rawValue, ascending: false)]
        outline.onSpace = { [weak self] in self?.toggleQuickLook() }
        outline.onCopy = { [weak self] in self?.copyPaths() }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
    }

    // MARK: State

    private var session: ScanSession? { model.session }

    func stateChanged() {
        volumePopup.removeAllItems()
        for volume in model.listedVolumes {
            let gone = model.sessions[volume.id]?.state == .volumeGone
            var title = volume.name + (volume.availableBytes > 0 ? "  —  " + LF("%@ free", Format.bytes(volume.availableBytes)) : "")
            if gone { title = volume.name + "  —  " + L("disconnected") }
            else if volume.kind == .timeMachine { title += "  ·  " + L("Time Machine, view only") }
            else if !volume.canTrash { title += "  ·  " + L("read-only") }
            volumePopup.addItem(withTitle: title)
            volumePopup.lastItem?.representedObject = volume.id
            volumePopup.lastItem?.image = NSImage(systemSymbolName: volume.kind == .startupData ? "internaldrive" : volume.kind == .timeMachine ? "clock.arrow.circlepath" : "externaldrive", accessibilityDescription: nil)
        }
        if let id = model.selectedVolume?.id, let index = volumePopup.itemArray.firstIndex(where: { $0.representedObject as? String == id }) {
            volumePopup.selectItem(at: index)
        }
        accessBanner.isHidden = model.hasFullDiskAccess || model.env.isSandbox

        let session = self.session
        if shownSessionID != session.map(ObjectIdentifier.init) {
            shownSessionID = session.map(ObjectIdentifier.init)
            resetTree()
        }
        if let session, session.isScanning {
            scanButton.title = L("Stop")
            spinner.startAnimation(nil)
        } else {
            scanButton.title = session == nil ? L("Scan") : L("Scan Again")
            spinner.stopAnimation(nil)
        }
        scanButton.isEnabled = model.selectedVolume.map { v in model.volumes.contains { $0.id == v.id } } ?? false
        updateStatus()
        updateSelection()
        if flatResults == nil && model.filter.isFlat, session?.isScanning == false { runSearch() }
    }

    private func updateStatus() {
        guard let volume = model.selectedVolume else {
            statusLabel.stringValue = L("No disk")
            summaryLabel.stringValue = ""
            return
        }
        guard let session = model.sessions[volume.id] else {
            statusLabel.stringValue = L("Not scanned yet.")
            summaryLabel.stringValue = volume.usedBytes == 0 ? "" : LF("%@ used on this disk (as df reports).", Format.bytes(volume.usedBytes))
            noticeLabel.isHidden = true
            return
        }
        let count = session.store.count
        switch session.state {
        case .scanning:
            statusLabel.stringValue = LF("Scanning… %@ items, %@ so far", Format.count(count), Format.bytes(session.store.size(0)))
        case .finished:
            statusLabel.stringValue = LF("%@ items in %.1f s", Format.count(count), session.summary?.duration ?? 0)
        case .cancelled:
            statusLabel.stringValue = LF("Stopped: %@ items. Totals are incomplete.", Format.count(count))
        case .volumeGone:
            statusLabel.stringValue = L("The disk was disconnected. What was scanned is shown for viewing only.")
        }
        let scanned = session.summary?.estimatedOnDisk ?? session.store.size(0)
        let used = volume.usedBytes
        var text = LF("Used (df): %@  ·  Found by the scan: %@", Format.bytes(used), Format.bytes(scanned))
        if used == 0 { text = LF("Found by the scan: %@", Format.bytes(scanned)) }
        if session.state == .finished, used > 0 {
            let gap = Int64(used) - Int64(scanned)
            text += "  ·  " + LF("Not visible to the scan: %@ (%.1f%%)", Format.bytes(UInt64(max(0, gap))), Double(gap) / Double(used) * 100)
        }
        summaryLabel.stringValue = text
        var notices: [String] = []
        if session.state == .volumeGone { notices.append(L("This disk is no longer connected: nothing on it can be moved to the Trash.")) }
        if session.volume.kind == .timeMachine { notices.append(L("Time Machine backups are shown for viewing only.")) }
        else if !session.volume.canTrash { notices.append(L("This disk is read-only (or NTFS): nothing on it can be moved to the Trash.")) }
        noticeLabel.stringValue = notices.joined(separator: " ")
        noticeLabel.isHidden = notices.isEmpty
    }

    private func updateSelection() {
        let (count, bytes) = model.selection
        selectionLabel.stringValue = count == 0 ? L("Nothing ticked") : LF("Ticked: %@ items, %@", Format.count(count), Format.bytes(bytes))
        let canRemove = session.map { $0.state == .finished || $0.state == .cancelled } ?? false
        trashButton.isEnabled = count > 0 && canRemove && !model.isSearching && (session?.volume.canTrash ?? false)
        untickButton.isEnabled = count > 0
        suggestionsButton.isEnabled = model.startupSession.map { !$0.isScanning } ?? false
    }

    // MARK: Tree updates

    private func resetTree() {
        items.removeAll()
        childCache.removeAll()
        flatResults = nil
        outline.reloadData()
    }

    private func item(_ id: NodeID) -> NodeItem {
        if let existing = items[id] { return existing }
        let new = NodeItem(id)
        items[id] = new
        return new
    }

    private func children(of id: NodeID) -> [NodeID] {
        if let cached = childCache[id] { return cached }
        guard let session else { return [] }
        let result = Browse.children(of: id, in: session.store, order: model.order, filter: model.filter)
        childCache[id] = result
        return result
    }

    /// New entries arrived (or items were removed: `touched` empty). Reloads at most four times a
    /// second, and only what is visible or open, so a large scan does not make the list jump around.
    private func treeChanged(_ touched: Set<NodeID>) {
        if touched.isEmpty {
            reloadKeepingExpansion()
            updateStatus()
            updateSelection()
            return
        }
        pendingTouched.formUnion(touched)
        guard !reloadScheduled else { return }
        let wait = max(0, 0.25 - Date().timeIntervalSince(lastReload))
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.applyPendingChanges() }
        }
    }

    private func applyPendingChanges() {
        reloadScheduled = false
        lastReload = Date()
        let touched = pendingTouched
        pendingTouched.removeAll()
        updateStatus()
        guard flatResults == nil, let session else { return }
        // Sizes changed all the way up: drop cached orders of open folders, reload those whose
        // children changed or whose order may have, keep the rest in place.
        var reloadParents = Set<NodeID>()
        for id in touched {
            var node: NodeID? = id
            while let n = node {
                if n == 0 || outline.isItemExpanded(items[n]) { reloadParents.insert(n) }
                node = session.store.parent(of: n)
            }
        }
        for id in reloadParents { childCache[id] = nil }
        let selected = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? NodeItem)?.id }
        for id in reloadParents.sorted() {
            if id == 0 { outline.reloadItem(nil, reloadChildren: true) }
            else if let it = items[id], outline.row(forItem: it) >= 0 { outline.reloadItem(it, reloadChildren: true) }
        }
        restoreSelection(selected)
    }

    private func reloadKeepingExpansion() {
        let expanded = items.values.filter { outline.isItemExpanded($0) }.map(\.id)
        let selected = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? NodeItem)?.id }
        childCache.removeAll()
        if model.filter.isFlat { runSearch() }
        outline.reloadData()
        for id in expanded.sorted() where session?.store.isInTree(id) ?? false {
            if let it = items[id] { outline.expandItem(it) }
        }
        restoreSelection(selected)
    }

    private func restoreSelection(_ ids: [NodeID]) {
        let rows = IndexSet(ids.compactMap { items[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard session != nil else { return 0 }
        if let node = item as? NodeItem { return children(of: node.id).count }
        return flatResults?.count ?? children(of: 0).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? NodeItem { return self.item(children(of: node.id)[index]) }
        return self.item(flatResults?[index] ?? children(of: 0)[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard flatResults == nil, let node = item as? NodeItem, let session else { return false }
        return session.store.isExpandable(node.id, intoPackages: model.intoPackages)
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let column = SortColumn(rawValue: descriptor.key ?? "") else { return }
        model.order = SortOrder(column: column, ascending: descriptor.ascending)
        if let flat = flatResults, let session { flatResults = Browse.sort(flat, in: session.store, order: model.order) }
        reloadKeepingExpansion()
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let column = tableColumn, let node = item as? NodeItem, let session else { return nil }
        let store = session.store
        let id = node.id
        switch column.identifier.rawValue {
        case "name":
            let cell = (outlineView.makeView(withIdentifier: NameCell.identifier, owner: nil) as? NameCell) ?? NameCell()
            cell.configure(name: store.name(id), icon: Icons.icon(for: id, in: store))
            let ancestor = model.tickedAncestor(of: id, in: session)
            let verdict = model.verdict(id, in: session)
            cell.checkbox.state = ancestor == id ? .on : ancestor != nil ? .mixed : .off
            cell.checkbox.isEnabled = verdict.isAllowed && (ancestor == nil || ancestor == id)
            cell.lock.isHidden = verdict.isAllowed
            var tip = store.path(id)
            if case .denied(let reason) = verdict { tip += "\n" + L("View only:") + " " + R(reason) }
            let flags = store.flags(id)
            if flags.contains(.dataless) { tip += "\n" + L("In iCloud, not downloaded: takes no space here.") }
            if flags.contains(.hardLinkExtra) { tip += "\n" + L("Hard link to a file counted elsewhere: not counted again.") }
            if flags.contains(.clone) { tip += "\n" + L("APFS clone: shares space with another file, removing it may free less.") }
            if flags.contains(.unreadable) { tip += "\n" + (session.summary?.needsFullDiskAccess.contains(store.scanPath(id)) == true
                ? L("Left out: needs Full Disk Access.") : L("Could not be read.")) }
            cell.toolTip = tip
            cell.textField?.textColor = flags.contains(.unreadable) || flags.contains(.dataless) ? .secondaryLabelColor : .labelColor
            cell.onToggle = { [weak self] in self?.toggle(id) }
            return cell
        case "size":
            let text = store.flags(id).contains(.unreadable) && store.size(id) == 0 ? "—" : Format.bytes(store.size(id))
            return label(outlineView, "size", text, alignment: .right)
        case "created":
            return label(outlineView, "created", store.birthDate(id).map { Format.date.string(from: $0) } ?? "—")
        case "modified":
            return label(outlineView, "modified", store.modifiedDate(id).map { Format.date.string(from: $0) } ?? "—")
        default:
            return label(outlineView, "kind", Icons.kind(for: id, in: store))
        }
    }

    private func label(_ outlineView: NSOutlineView, _ id: String, _ text: String, alignment: NSTextAlignment = .left) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("label-" + id)
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            field.textColor = .secondaryLabelColor
            c.addSubview(field)
            c.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = text
        cell.textField?.alignment = alignment
        cell.textField?.font = alignment == .right ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
        return cell
    }

    private func toggle(_ id: NodeID) {
        if let reason = model.toggleTick(id) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("This item can only be viewed")
            alert.informativeText = R(reason)
            alert.beginSheetModal(for: window!)
        }
        refreshVisibleRows()
        updateSelection()
    }

    private func refreshVisibleRows() {
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
                           columnIndexes: IndexSet(integer: 0))
    }

    // MARK: Actions

    @objc private func volumeChosen() {
        model.selectedVolumeID = volumePopup.selectedItem?.representedObject as? String
        flatResults = nil
        stateChanged()
        if let volume = model.selectedVolume, model.sessions[volume.id] == nil { model.scan(volume) }
    }

    @objc func scanOrCancel() {
        if let session, session.isScanning {
            model.cancelScan()
        } else if let volume = model.selectedVolume, model.volumes.contains(where: { $0.id == volume.id }) {
            model.scan(volume)
        }
    }

    /// Starts the first scan when the window first appears.
    func scanIfNeeded() {
        if let volume = model.selectedVolume, model.sessions[volume.id] == nil { model.scan(volume) }
    }

    @objc private func filterChanged() {
        model.filter = BrowseFilter(name: searchField.stringValue,
                                    minimumSize: Self.sizeSteps[max(0, sizePopup.indexOfSelectedItem)],
                                    minimumAgeDays: Self.ageSteps[max(0, agePopup.indexOfSelectedItem)])
        if model.filter.isFlat { runSearch() } else { flatResults = nil }
        reloadKeepingExpansion()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Wait for a pause in typing before searching a million names.
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.filterChanged() } }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Searching two million names takes seconds: it runs off the main thread on the finished tree.
    /// Nothing changes the tree meanwhile (the Trash button waits), and a newer search replaces it.
    private func runSearch() {
        guard let session, model.filter.isFlat else { flatResults = nil; return }
        if session.isScanning {
            statusLabel.stringValue = L("Name and age filters apply when the scan ends.")
            flatResults = []
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        let snapshot = StoreSnapshot(store: session.store)
        let filter = model.filter
        let order = model.order
        model.isSearching = true
        flatResults = []
        spinner.startAnimation(nil)
        statusLabel.stringValue = L("Searching…")
        updateSelection()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Browse.matches(in: snapshot.store, filter: filter, order: order, now: Date())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.searchGeneration else { return }
                    self.model.isSearching = false
                    self.spinner.stopAnimation(nil)
                    guard self.model.filter == filter, self.session === session else { self.updateSelection(); return }
                    self.flatResults = result.ids
                    self.flatTruncated = result.truncated
                    self.outline.reloadData()
                    self.updateStatus()
                    if result.truncated { self.statusLabel.stringValue = LF("Showing the first %@ matches.", Format.count(result.ids.count)) }
                    else { self.statusLabel.stringValue = LF("%@ matches.", Format.count(result.ids.count)) }
                    self.updateSelection()
                }
            }
        }
    }

    @objc private func packagesToggled() {
        model.intoPackages = packagesCheck.state == .on
        reloadKeepingExpansion()
    }

    @objc private func showDetails() {
        guard let volume = model.selectedVolume else { return }
        let alert = NSAlert()
        alert.messageText = LF("Where the space on %@ goes", volume.name)
        alert.informativeText = DetailsText.make(volume: volume, session: model.sessions[volume.id])
        alert.beginSheetModal(for: window!)
    }

    @objc private func openPrivacy() {
        let alert = NSAlert()
        alert.messageText = L("Give Mac Clean Full Disk Access")
        alert.informativeText = L("In System Settings → Privacy & Security → Full Disk Access, click +, choose Mac Clean in Applications, and switch it on. Mac Clean does not appear in the list by itself. Then quit and reopen Mac Clean and scan again.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { Permissions.openFullDiskAccessSettings() }
    }

    @objc private func untickAll() {
        model.untickAll()
        refreshVisibleRows()
        updateSelection()
    }

    @objc private func openSuggestions() { onOpenSuggestions?() }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? NodeItem else { return }
        if outline.isExpandable(node) {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        }
    }

    // MARK: Moving to the Trash

    @objc func moveToTrash() {
        guard !model.isSearching, let plan = model.makePlan(), let window else { return }
        if plan.items.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("Nothing can be moved")
            alert.informativeText = plan.rejected.map { $0.path + ": " + R($0.reason) }.prefix(10).joined(separator: "\n")
            alert.beginSheetModal(for: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = LF("Move %@ items (%@) to the Trash?", Format.count(plan.items.count), Format.bytes(plan.totalBytes))
        var info = plan.items.prefix(12).map(\.path).joined(separator: "\n")
        if plan.items.count > 12 { info += "\n" + LF("…and %@ more", Format.count(plan.items.count - 12)) }
        if !plan.rejected.isEmpty {
            info += "\n\n" + LF("%@ ticked items will be left alone:", Format.count(plan.rejected.count)) + "\n"
                + plan.rejected.prefix(5).map { $0.path + ": " + R($0.reason) }.joined(separator: "\n")
        }
        info += "\n\n" + L("They can be put back from the Trash. Mac Clean never empties the Trash.")
        alert.informativeText = info
        alert.addButton(withTitle: L("Move to Trash"))
        alert.addButton(withTitle: L("Cancel"))
        if !plan.adminItems.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = LF("Also move %@ items owned by the system (asks for an administrator password)", Format.count(plan.adminItems.count))
            alert.suppressionButton?.state = .off
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let includeAdmin = alert.suppressionButton?.state == .on
            self.trashButton.isEnabled = false
            self.model.execute(plan, includeAdmin: includeAdmin) { outcomes in self.showOutcomes(outcomes) }
        }
    }

    private func showOutcomes(_ outcomes: [ItemOutcome]) {
        guard let window else { return }
        var trashed: [TrashRecord] = []
        var problems: [String] = []
        for outcome in outcomes {
            switch outcome.status {
            case .trashed(let record): trashed.append(record)
            case .skipped(let reason): problems.append(outcome.path + ": " + R(reason))
            case .failed(let error): problems.append(outcome.path + ": " + error)
            }
        }
        let alert = NSAlert()
        alert.messageText = LF("Moved %@ items to the Trash (%@).", Format.count(trashed.count), Format.bytes(trashed.reduce(0) { $0 + $1.bytes }))
        alert.informativeText = problems.isEmpty ? L("Everything ticked was moved.")
            : LF("%@ items were not moved:", Format.count(problems.count)) + "\n" + problems.prefix(10).joined(separator: "\n")
        alert.addButton(withTitle: L("OK"))
        if !trashed.isEmpty { alert.addButton(withTitle: L("Delete These for Good…")) }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.confirmDeleteForGood(trashed) }
        }
    }

    private func confirmDeleteForGood(_ records: [TrashRecord]) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = LF("Delete %@ items for good?", Format.count(records.count))
        alert.informativeText = L("Only the items Mac Clean just moved to the Trash are deleted, and only if they are still there unchanged. This cannot be undone.")
        alert.addButton(withTitle: L("Delete for Good"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.model.deleteForGood(records) { outcomes in
                let failed = outcomes.filter { $0.error != nil }
                let done = NSAlert()
                done.messageText = LF("Deleted %@ items for good.", Format.count(outcomes.count - failed.count))
                if !failed.isEmpty {
                    done.informativeText = failed.prefix(10).map { $0.record.trashed + ": " + R($0.error!) }.joined(separator: "\n")
                }
                done.beginSheetModal(for: window)
            }
        }
    }

    // MARK: Context menu, Quick Look, Finder

    private var selectedIDs: [NodeID] {
        var rows = outline.selectedRowIndexes
        if outline.clickedRow >= 0 && !rows.contains(outline.clickedRow) { rows = IndexSet(integer: outline.clickedRow) }
        return rows.compactMap { (outline.item(atRow: $0) as? NodeItem)?.id }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !selectedIDs.isEmpty else { return }
        menu.addItem(withTitle: L("Quick Look"), action: #selector(quickLookSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Show in Finder"), action: #selector(revealSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Copy Path"), action: #selector(copyPathsAction), keyEquivalent: "").target = self
    }

    @objc private func revealSelected() {
        guard let session else { return }
        let urls = selectedIDs.map { URL(fileURLWithPath: session.store.path($0)) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func copyPathsAction() { copyPaths() }

    func copyPaths() {
        guard let session, !selectedIDs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedIDs.map { session.store.path($0) }.joined(separator: "\n"), forType: .string)
    }

    @objc private func quickLookSelected() { toggleQuickLook() }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    /// Items Quick Look may show. Not iCloud placeholders: previewing one would download it.
    private var previewURLs: [URL] {
        guard let session else { return [] }
        return selectedIDs.filter { !session.store.flags($0).contains(.dataless) && !session.store.flags($0).contains(.unreadable) }
            .map { URL(fileURLWithPath: session.store.path($0)) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { previewURLs.count } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewURLs[index] as NSURL }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshPermissions()
        accessBanner.isHidden = model.hasFullDiskAccess || model.env.isSandbox
    }
}

/// The outline with Space for Quick Look and Copy for paths.
final class TreeOutlineView: NSOutlineView {
    var onSpace: (() -> Void)?
    var onCopy: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onSpace?(); return }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { onCopy?() }
}

/// Name column: tick box, icon, name, and a lock for items that can only be viewed.
final class NameCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("name")
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let icon = NSImageView()
    let lock = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "view only")!)
    var onToggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        checkbox.allowsMixedState = true
        checkbox.target = self
        checkbox.action = #selector(clicked)
        lock.contentTintColor = .systemRed
        lock.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.alignment = .left
        textField = field
        imageView = icon
        for v in [checkbox, icon, field, lock] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 18),
            icon.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: lock.leadingAnchor, constant: -4),
            lock.centerYAnchor.constraint(equalTo: centerYAnchor),
            lock.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            lock.widthAnchor.constraint(equalToConstant: 10),
        ])
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, icon image: NSImage) {
        textField?.stringValue = name
        icon.image = image
    }

    @objc private func clicked() { onToggle?() }
}

/// Icons and kinds from the name only: nothing is read from the disk (so no iCloud download).
@MainActor
enum Icons {
    private static var byType: [String: NSImage] = [:]
    private static var kinds: [String: String] = [:]

    static func icon(for id: NodeID, in store: NodeStore) -> NSImage {
        let key: String
        let type: UTType
        switch store.kind(id) {
        case .directory:
            let ext = (store.name(id) as NSString).pathExtension.lowercased()
            if store.flags(id).contains(.package), let t = UTType(filenameExtension: ext) { key = "pkg." + ext; type = t }
            else { key = "folder"; type = .folder }
        case .symlink: key = "link"; type = .symbolicLink
        case .file:
            let ext = (store.name(id) as NSString).pathExtension.lowercased()
            key = "file." + ext
            type = UTType(filenameExtension: ext) ?? .data
        case .other: key = "other"; type = .item
        }
        if let cached = byType[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        byType[key] = image
        return image
    }

    static func kind(for id: NodeID, in store: NodeStore) -> String {
        let ext = (store.name(id) as NSString).pathExtension.lowercased()
        switch store.kind(id) {
        case .directory where !store.flags(id).contains(.package): return L("Folder")
        case .symlink: return L("Alias (symbolic link)")
        case .other: return L("Other")
        default: break
        }
        if let cached = kinds[ext] { return cached }
        let text = UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? L("Document") : ext.uppercased())
        kinds[ext] = text
        return text
    }
}

/// The "where does the space go" explanation for a volume.
@MainActor
enum DetailsText {
    static func make(volume: Volume, session: ScanSession?) -> String {
        var lines: [String] = []
        lines.append(LF("Used by this volume (as df reports): %@", Format.bytes(volume.usedBytes)))
        if let s = session?.summary {
            lines.append(LF("Found by the scan (hard links once, clone sharing estimated): %@", Format.bytes(s.estimatedOnDisk)))
            if s.cloneSharedOvercount > 0 { lines.append("  " + LF("APFS clones share %@ that would otherwise be counted twice.", Format.bytes(s.cloneSharedOvercount))) }
            if s.hardLinkExtras > 0 { lines.append("  " + LF("%@ hard links counted once (%@ not counted again).", Format.count(s.hardLinkExtras), Format.bytes(s.hardLinkExtraBytes))) }
            if s.datalessFiles > 0 { lines.append("  " + LF("%@ iCloud files are not downloaded (%@ online, not on this disk).", Format.count(s.datalessFiles), Format.bytes(s.datalessLogicalBytes))) }
            if s.purgeableBytes > 0 { lines.append("  " + LF("Purgeable files that macOS may remove by itself: %@.", Format.bytes(s.purgeableBytes))) }
            if s.systemFolderBytes > 0 { lines.append(LF("Spotlight index, file events and other bookkeeping: %@ (not shown, never removed).", Format.bytes(s.systemFolderBytes))) }
            let gap = Int64(volume.usedBytes) - Int64(s.estimatedOnDisk) - Int64(s.systemFolderBytes)
            lines.append("")
            lines.append(LF("Not visible to a file scan: %@", Format.bytes(UInt64(max(0, gap)))))
            lines.append("  " + L("Folders the system does not let any app read, local snapshots, APFS metadata, and space macOS counts as purgeable."))
            if !s.needsFullDiskAccess.isEmpty {
                lines.append("  " + LF("%@ folders were left out because Mac Clean has no Full Disk Access.", Format.count(s.needsFullDiskAccess.count)))
            }
            if s.unreadableCount > 0 {
                lines.append("  " + LF("%@ folders could not be read, for example:", Format.count(s.unreadableCount)))
                for path in s.unreadableFolders.prefix(8) { lines.append("    " + path) }
            }
        }
        if !volume.otherParts.isEmpty {
            lines.append("")
            lines.append(L("On the same disk, outside this volume:"))
            for part in volume.otherParts { lines.append("  " + L(part.name) + ": " + Format.bytes(part.bytes)) }
        }
        return lines.joined(separator: "\n")
    }
}

/// Hands the finished tree to a background search. Safe because nothing changes the tree while
/// `AppModel.isSearching` is set (scans are over, and removal waits).
struct StoreSnapshot: @unchecked Sendable {
    let store: NodeStore
}
