import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One native outline owns selection and mouse tracking. Cells are reused by
/// AppKit, regardless of the number of children in an expanded directory.
struct RemoteFileOutlineView: NSViewRepresentable {
    @ObservedObject var store: RemoteFileStore
    let availableProfiles: [ServerProfile]
    let supportedTextFilePatterns: String
    let editAction: (RemoteFileItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        let outline = FileOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.focusRingType = .none
        outline.backgroundColor = .controlBackgroundColor
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openClickedItem)
        outline.coordinator = context.coordinator
        outline.registerForDraggedTypes([.fileURL, RemoteFilePromiseProvider.remoteType])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        scroll.documentView = outline
        context.coordinator.outline = outline
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Node: NSObject {
        var item: RemoteFileItem?
        let path: String
        let newFolderParent: String?
        init(item: RemoteFileItem) {
            self.item = item
            path = item.path
            newFolderParent = nil
        }
        init(parent: String) {
            path = "\0new:" + parent
            newFolderParent = parent
        }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        var parent: RemoteFileOutlineView
        weak var outline: FileOutlineView?
        private var nodes: [String: Node] = [:]
        private var listings: [String: [RemoteFileItem]] = [:]
        private var rootPath = ""
        private var revision = -1
        private var newFolderParent: String?
        private var syncing = false
        private var lastExpanded: Set<String> = []
        private(set) var editingNode: Node?
        private weak var editingField: NSTextField?
        private var editingSelection: NSRange?
        private var drafts: [String: String] = [:]
        private var menuActions: [() -> Void] = []
        private var dragProvider: RemoteFilePromiseProvider?

        init(_ parent: RemoteFileOutlineView) { self.parent = parent }
        var store: RemoteFileStore { parent.store }

        private func node(_ item: RemoteFileItem) -> Node {
            if let existing = nodes[item.path] { existing.item = item; return existing }
            let result = Node(item: item)
            nodes[item.path] = result
            return result
        }

        private func newNode(_ path: String) -> Node {
            let key = "\0new:" + path
            if let existing = nodes[key] { return existing }
            let result = Node(parent: path)
            nodes[key] = result
            return result
        }

        func update(_ parent: RemoteFileOutlineView) {
            self.parent = parent
            guard let outline else { return }
            syncing = true
            defer { syncing = false }
            let treeChanged = revision != store.treeRevision
            if treeChanged {
                if let editingNode, let editor = editingField?.currentEditor() {
                    drafts[editingNode.path] = editor.string
                    editingSelection = editor.selectedRange
                }
                let oldRoot = rootPath
                let oldListings = listings
                let oldNewFolder = newFolderParent
                rootPath = store.currentPath
                listings = store.childrenByPath.mapValues { store.visibleItems($0) }
                listings[rootPath] = store.visibleItems(store.items)
                newFolderParent = store.newFolderParent
                revision = store.treeRevision
                var changedParents: Set<String> = []
                var changedItems: [Node] = []
                var validPaths: Set<String> = []
                for (path, items) in listings {
                    let old = oldListings[path] ?? []
                    if old.map(\.path) != items.map(\.path) { changedParents.insert(path) }
                    for item in items {
                        validPaths.insert(item.path)
                        if let existing = nodes[item.path], existing.item != item {
                            existing.item = item
                            changedItems.append(existing)
                        }
                    }
                }
                for removed in Set(oldListings.keys).subtracting(listings.keys) { changedParents.insert(removed) }
                if oldNewFolder != newFolderParent {
                    if let oldNewFolder { changedParents.insert(oldNewFolder) }
                    if let newFolderParent { changedParents.insert(newFolderParent) }
                }
                if let newFolderParent { validPaths.insert(newNode(newFolderParent).path) }
                if let editingNode, !validPaths.contains(editingNode.path) { cancelEditing() }
                let savedOrigin = outline.enclosingScrollView?.contentView.bounds.origin
                if oldRoot != rootPath || changedParents.contains(rootPath) {
                    outline.reloadData()
                } else {
                    for path in changedParents {
                        if let node = nodes[path] { outline.reloadItem(node, reloadChildren: true) }
                    }
                    for node in changedItems { outline.reloadItem(node) }
                }
                nodes = nodes.filter { validPaths.contains($0.key) }
                drafts = drafts.filter { validPaths.contains($0.key) }
                restoreExpansion()
                if let savedOrigin, oldRoot == rootPath, let scroll = outline.enclosingScrollView {
                    scroll.contentView.scroll(to: savedOrigin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                if let newFolderParent, oldNewFolder != newFolderParent {
                    let node = newNode(newFolderParent)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.store.newFolderParent == newFolderParent else { return }
                        self.beginEditing(node)
                    }
                }
            }
            if !treeChanged && lastExpanded != store.expandedPaths { restoreExpansion() }
            lastExpanded = store.expandedPaths
            let indexes = IndexSet(store.selectedPaths.compactMap { path in
                guard let node = nodes[path] else { return nil }
                let row = outline.row(forItem: node)
                return row >= 0 ? row : nil
            })
            if indexes != outline.selectedRowIndexes { outline.selectRowIndexes(indexes, byExtendingSelection: false) }
            let selectedPaths = store.selectedPaths
            let visibleSelection = Set(indexes.compactMap { (outline.item(atRow: $0) as? Node)?.item?.path })
            if visibleSelection != selectedPaths {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.store.selectedPaths == selectedPaths else { return }
                    self.store.setSelection(visibleSelection)
                }
            }
            if treeChanged, let editingNode, editingField?.currentEditor() == nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.editingNode === editingNode else { return }
                    self.beginEditing(editingNode)
                }
            }
            // Progress and selection updates touch only already-created cells.
            outline.enumerateAvailableRowViews { _, row in
                guard let node = outline.item(atRow: row) as? Node,
                      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView else { return }
                self.configure(cell, node: node)
            }
        }

        private func restoreExpansion() {
            guard let outline else { return }
            // Walk displayed rows, not the entire cached tree, and never expand
            // recursively (including when a link points back to an ancestor).
            var row = 0
            while row < outline.numberOfRows {
                if let node = outline.item(atRow: row) as? Node, node.item?.isBrowsableDirectory == true {
                    let expanded = store.expandedPaths.contains(node.path)
                    if expanded && !outline.isItemExpanded(node) { outline.expandItem(node) }
                    if !expanded && outline.isItemExpanded(node) { outline.collapseItem(node) }
                }
                row += 1
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            let path = (item as? Node)?.path ?? rootPath
            return (listings[path]?.count ?? 0) + (newFolderParent == path ? 1 : 0)
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let path = (item as? Node)?.path ?? rootPath
            let offset = newFolderParent == path ? 1 : 0
            if offset == 1 && index == 0 { return newNode(path) }
            return node(listings[path]![index - offset])
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Node)?.item?.isBrowsableDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("RemoteFileCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? FileCellView ?? FileCellView()
            cell.identifier = identifier
            configure(cell, node: node)
            return cell
        }

        private func configure(_ cell: FileCellView, node: Node) {
            let editing = editingNode === node
            if !editing || cell.textField !== editingField {
                cell.textField?.stringValue = drafts[node.path] ?? node.item?.name ?? NSLocalizedString("Untitled Folder", comment: "Default name for a new remote folder")
            }
            cell.alphaValue = 1
            cell.textField?.isEditable = editing
            cell.textField?.isSelectable = editing
            cell.textField?.delegate = self
            guard let item = node.item else {
                cell.imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
                cell.imageView?.contentTintColor = .controlAccentColor
                cell.badge.stringValue = ""
                return
            }
            if item.kind == .symbolicLink {
                DispatchQueue.main.async { [weak self] in self?.store.resolveVisibleLink(item) }
            }
            let symbol = item.isBrowsableDirectory ? "folder.fill" : (item.kind == .symbolicLink ? "link" : (isEditable(item) ? "doc.text" : "doc"))
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = item.isBrowsableDirectory ? .controlAccentColor : .secondaryLabelColor
            cell.alphaValue = item.isHidden ? 0.6 : 1
            cell.toolTip = item.path
            if store.isLoading(item) { cell.badge.stringValue = "…" }
            else if store.isDownloading(item) { cell.badge.stringValue = "↓" }
            else if store.isUploading(to: store.uploadTarget(for: item)) { cell.badge.stringValue = "↑" }
            else if store.isMoving(item) { cell.badge.stringValue = "→" }
            else { cell.badge.stringValue = "" }
        }

        private func isEditable(_ item: RemoteFileItem) -> Bool {
            AppPreferences.isTextEditableFile(item, patternsValue: parent.supportedTextFilePatterns)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            let paths = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.item?.path })
            store.setSelection(paths)
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            editingNode == nil && (item as? Node)?.item != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool { false }
        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool { syncing || editingNode == nil }
        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { syncing || editingNode == nil }

        func outlineViewItemDidExpand(_ notification: Notification) { syncExpansion(notification, expanded: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { syncExpansion(notification, expanded: false) }
        private func syncExpansion(_ notification: Notification, expanded: Bool) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? Node, let item = node.item else { return }
            if store.isExpanded(item) != expanded { store.open(item) }
            if !expanded, let outline {
                let visible = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.item?.path })
                store.setSelection(visible)
            }
        }

        @objc func openClickedItem() {
            guard editingNode == nil, let outline, !outline.clickedDisclosure,
                  outline.clickModifiers.intersection([.command, .shift, .control, .option]).isEmpty,
                  outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
            if let item = node.item { activate(item) }
            else { beginEditing(node) }
        }

        func activate(_ item: RemoteFileItem) {
            guard editingNode == nil else { return }
            if item.isBrowsableDirectory { store.open(item) }
            else if isEditable(item) { parent.editAction(item) }
        }

        func escape() {
            if editingNode != nil { cancelEditing() }
            else { store.clearSelection(); outline?.deselectAll(nil) }
        }

        private func beginEditing(_ node: Node) {
            guard let outline else { return }
            if editingNode === node, editingField?.currentEditor() != nil { return }
            if editingNode !== node { cancelEditing() }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            outline.scrollRowToVisible(row)
            editingNode = node
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCellView,
                  let field = cell.textField else { editingNode = nil; return }
            field.stringValue = drafts[node.path] ?? node.item?.name ?? NSLocalizedString("Untitled Folder", comment: "Default name for a new remote folder")
            editingField = field
            field.isEditable = true
            field.isSelectable = true
            guard outline.window?.makeFirstResponder(field) == true,
                  let editor = field.currentEditor() else { return }
            // selectText starts another editing session and ends the first one,
            // which our delegate interprets as cancellation. Select in place.
            let name = editor.string as NSString
            let length = name.length
            // For files, leave the final extension intact when typing a new name.
            // Dotfiles without an extension and directory names stay fully selected.
            let initialLength = node.item?.isBrowsableDirectory == false && !name.pathExtension.isEmpty
                ? (name.deletingPathExtension as NSString).length : length
            let selection = editingSelection ?? NSRange(location: 0, length: initialLength)
            let location = min(selection.location, length)
            editor.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        }

        private func cancelEditing() {
            let wasNew = editingNode?.newFolderParent != nil
            let node = editingNode
            let field = editingField
            editingNode = nil
            editingField = nil
            editingSelection = nil
            field?.abortEditing()
            field?.isEditable = false
            field?.isSelectable = false
            if let node {
                drafts.removeValue(forKey: node.path)
                field?.stringValue = node.item?.name ?? NSLocalizedString("Untitled Folder", comment: "Default name for a new remote folder")
            }
            if wasNew && store.newFolderParent == node?.newFolderParent { store.cancelNewFolder() }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard control === editingField else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelEditing(); return true }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), let node = editingNode,
                  let field = editingField else { return false }
            let accepted: Bool
            if let item = node.item { accepted = store.rename(item, to: field.stringValue) }
            else if let parent = node.newFolderParent { accepted = store.createFolder(named: field.stringValue, in: parent) }
            else { return true }
            if accepted {
                if node.newFolderParent != nil { drafts[node.path] = field.stringValue }
                else {
                    drafts.removeValue(forKey: node.path)
                    field.stringValue = node.item?.name ?? field.stringValue
                }
                // A new folder's placeholder remains until the request finishes.
                editingNode = nil
                editingField = nil
                editingSelection = nil
                field.isEditable = false
                field.isSelectable = false
                outline?.window?.makeFirstResponder(outline)
            }
            return true
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = editingField, obj.object as? NSTextField === field,
                  let node = editingNode else { return }
            drafts[node.path] = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = editingField, obj.object as? NSTextField === field else { return }
            if syncing {
                editingField = nil
            } else if editingNode != nil {
                cancelEditing()
            }
        }

        func editPlaceholder(at row: Int) -> Bool {
            guard editingNode == nil, let node = outline?.item(atRow: row) as? Node, node.newFolderParent != nil else { return false }
            beginEditing(node)
            return true
        }

        func contextMenu(at row: Int) -> NSMenu? {
            guard editingNode == nil, let outline else { return nil }
            menuActions.removeAll()
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, enabled: Bool = true, to destination: NSMenu? = nil, action: @escaping (Coordinator) -> Void) {
                let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: #selector(runMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.tag = menuActions.count
                item.isEnabled = enabled
                menuActions.append { [weak self] in
                    guard let self else { return }
                    action(self)
                }
                (destination ?? menu).addItem(item)
            }
            guard let item = (outline.item(atRow: row) as? Node)?.item else {
                add("New Folder...") { coordinator in coordinator.store.newFolder(in: coordinator.store.currentPath) }
                add("Paste", enabled: store.hasCopiedItems) { coordinator in coordinator.store.paste(to: coordinator.store.currentPath) }
                add("Upload Here...") { coordinator in coordinator.store.chooseAndUpload(to: coordinator.store.currentPath) }
                return menu
            }
            if !outline.isRowSelected(row) { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            let single = store.actionItems(for: item).count == 1
            let destination = store.uploadTarget(for: item)
            if isEditable(item) { add("Edit", enabled: single) { coordinator in coordinator.parent.editAction(item) } }
            if item.isBrowsableDirectory {
                add("Open in Terminal", enabled: single) { coordinator in coordinator.parent.editAction(item) }
                add(store.isExpanded(item) ? "Collapse" : "Expand") { coordinator in coordinator.store.open(item) }
            }
            menu.addItem(.separator())
            add("Copy") { coordinator in coordinator.store.copy(item) }
            add("Paste", enabled: store.hasCopiedItems) { coordinator in coordinator.store.paste(to: destination) }
            add("New Folder...", enabled: single) { coordinator in coordinator.store.newFolder(in: destination) }
            add(item.isBrowsableDirectory ? "Upload Here..." : "Upload...", enabled: single) { coordinator in coordinator.store.chooseAndUpload(to: destination) }
            add("Download...") { coordinator in coordinator.store.download(item) }
            let profiles = store.serverTransferTargets(from: parent.availableProfiles)
            if !profiles.isEmpty {
                let submenu = NSMenu()
                for profile in profiles { add(profile.displayName, to: submenu) { coordinator in coordinator.store.copyToServer(item, targetProfile: profile) } }
                let entry = NSMenuItem(title: NSLocalizedString("Copy to Server...", comment: ""), action: nil, keyEquivalent: "")
                entry.submenu = submenu
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            add("Rename...", enabled: single) { coordinator in coordinator.beginEditing(coordinator.node(item)) }
            add("Delete...") { coordinator in coordinator.store.delete(item) }
            return menu
        }

        @objc private func runMenuAction(_ sender: NSMenuItem) {
            guard menuActions.indices.contains(sender.tag) else { return }
            menuActions[sender.tag]()
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard editingNode == nil, let item = (item as? Node)?.item else { return nil }
            // A multi-selection is one promised payload, matching the existing
            // export contract, rather than N copies of the entire selection.
            if dragProvider != nil { return nil }
            guard let provider = store.makeFilePromise(for: item) else { return nil }
            dragProvider = provider
            return provider
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if let token = dragProvider?.token { AppDragRegistry.endRemoteFileDrag(token) }
            dragProvider = nil
        }

        private func dropTarget(_ item: Any?) -> String {
            guard let item = (item as? Node)?.item else { return store.currentPath }
            return store.uploadTarget(for: item)
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard editingNode == nil else { return [] }
            if let node = item as? Node, let file = node.item, !file.isBrowsableDirectory {
                let parent = outlineView.parent(forItem: node)
                outlineView.setDropItem(parent, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else { outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex) }
            if let value = info.draggingPasteboard.string(forType: RemoteFilePromiseProvider.remoteType), let token = UUID(uuidString: value) {
                return store.remoteDragOperation(token: token)
            }
            return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let target = dropTarget(item)
            if let value = info.draggingPasteboard.string(forType: RemoteFilePromiseProvider.remoteType), let token = UUID(uuidString: value) {
                return store.handleRemoteFileDrop(token: token, to: target)
            }
            let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []).compactMap { ($0 as? NSURL).map { $0 as URL } }
            guard !urls.isEmpty else { return false }
            store.uploadDroppedURLs(urls, to: target)
            return true
        }
    }
}

final class FileOutlineView: NSOutlineView {
    weak var coordinator: RemoteFileOutlineView.Coordinator?
    private(set) var clickedDisclosure = false
    private(set) var clickModifiers: NSEvent.ModifierFlags = []

    override func mouseDown(with event: NSEvent) {
        clickModifiers = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        clickedDisclosure = row >= 0 && frameOfOutlineCell(atRow: row).contains(point)
        if row < 0, coordinator?.editingNode == nil { deselectAll(nil) }
        if row >= 0, coordinator?.editPlaceholder(at: row) == true { return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.contextMenu(at: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { coordinator?.escape(); return }
        super.keyDown(with: event)
    }
}

private final class FileCellView: NSTableCellView {
    let badge = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.isEditable = false
        label.isSelectable = false
        badge.font = .systemFont(ofSize: 11)
        badge.textColor = .secondaryLabelColor
        for view in [icon, label, badge] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -3),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor), badge.widthAnchor.constraint(equalToConstant: 12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
