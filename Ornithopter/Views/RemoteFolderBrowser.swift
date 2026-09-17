//
//  RemoteFolderBrowser.swift
//  Ornithopter
//

import Combine
import Darwin
import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OSLog

private struct RemoteFileError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct NameValidation {
    let name: String?
    let message: String?

    nonisolated var isValid: Bool {
        message == nil
    }
}

private nonisolated struct RemoteSubprocessResult {
    let outputText: String
    let errorText: String
    let terminationStatus: Int32
}

private nonisolated struct RemoteTransferProgress: Sendable {
    let itemName: String
    let itemIndex: Int?
    let itemCount: Int?
    let percent: Int
}

private nonisolated struct RsyncProgressEvent {
    let itemName: String?
    let itemIndex: Int?
    let percent: Int
}

private nonisolated final class RsyncProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLine = ""
    private var currentItemName: String?
    private var seenItemNames: Set<String> = []
    private var itemIndex = 0
    private var lastEmittedItemName: String?
    private var lastEmittedPercent: Int?

    func append(_ text: String) -> RsyncProgressEvent? {
        lock.lock()
        defer { lock.unlock() }

        var latestEvent: RsyncProgressEvent?
        for character in text {
            if character == "\n" || character == "\r" {
                latestEvent = processLine(pendingLine) ?? latestEvent
                pendingLine.removeAll(keepingCapacity: true)
            } else {
                pendingLine.append(character)
            }
        }

        if let event = processLine(pendingLine) {
            latestEvent = event
        }

        return latestEvent
    }

    private func processLine(_ line: String) -> RsyncProgressEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let percent = Self.latestPercent(in: trimmed) {
            let name = currentItemName
            let index = itemIndexForCurrentName()
            guard percent != lastEmittedPercent || name != lastEmittedItemName else {
                return nil
            }

            lastEmittedPercent = percent
            lastEmittedItemName = name
            return RsyncProgressEvent(itemName: name, itemIndex: index, percent: percent)
        }

        guard Self.looksLikeItemName(trimmed) else {
            return nil
        }

        currentItemName = trimmed
        return nil
    }

    private func itemIndexForCurrentName() -> Int? {
        guard let currentItemName else {
            return nil
        }

        if !seenItemNames.contains(currentItemName) {
            seenItemNames.insert(currentItemName)
            itemIndex += 1
        }

        return itemIndex
    }

    private static func latestPercent(in text: String) -> Int? {
        var digits = ""
        var latest: Int?

        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if character == "%" {
                if let value = Int(digits), (0...100).contains(value) {
                    latest = value
                }
                digits.removeAll(keepingCapacity: true)
            } else {
                digits.removeAll(keepingCapacity: true)
            }
        }

        return latest
    }

    private static func looksLikeItemName(_ line: String) -> Bool {
        !line.hasPrefix("sending incremental file list")
            && !line.hasPrefix("receiving incremental file list")
            && !line.hasPrefix("sent ")
            && !line.hasPrefix("total size is ")
            && !line.hasPrefix("speedup is ")
            && !line.contains("%")
    }
}

private final class RemoteFolderChooserController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    enum Action {
        case choose
        case open
        case up
        case refresh
        case newFolder
        case cancel
    }

    let tableView = NSTableView()
    var action: Action = .cancel
    var folders: [RemoteFileItem]
    weak var panel: NSPanel?
    weak var messageLabel: NSTextField?
    weak var pathField: NSTextField?
    weak var emptyLabel: NSTextField?

    init(folders: [RemoteFileItem]) {
        self.folders = folders
        super.init()
    }

    var selectedFolderPath: String? {
        let row = tableView.selectedRow
        guard folders.indices.contains(row) else {
            return nil
        }

        return folders[row].path
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        folders.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard folders.indices.contains(row) else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("RemoteFolderCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier

        let imageView = cell.imageView ?? NSImageView(frame: NSRect(x: 8, y: 3, width: 18, height: 18))
        imageView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        imageView.contentTintColor = .controlAccentColor
        if imageView.superview == nil {
            cell.addSubview(imageView)
        }
        cell.imageView = imageView

        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.frame = NSRect(x: 34, y: 3, width: max(40, tableView.bounds.width - 42), height: 18)
        textField.autoresizingMask = [.width]
        textField.lineBreakMode = .byTruncatingMiddle
        if textField.superview == nil {
            cell.addSubview(textField)
        }
        textField.stringValue = folders[row].name
        cell.textField = textField

        return cell
    }

    func update(path: String, message: String, folders: [RemoteFileItem]) {
        self.folders = folders
        pathField?.stringValue = path
        messageLabel?.stringValue = message
        emptyLabel?.isHidden = !folders.isEmpty
        tableView.reloadData()
        tableView.deselectAll(nil)
    }

    @objc func chooseFolder() {
        finish(.choose)
    }

    @objc func openFolder() {
        guard selectedFolderPath != nil else {
            return
        }

        finish(.open)
    }

    @objc func goUp() {
        finish(.up)
    }

    @objc func refresh() {
        finish(.refresh)
    }

    @objc func newFolder() {
        finish(.newFolder)
    }

    @objc func cancel() {
        finish(.cancel)
    }

    @objc func doubleClickRow() {
        openFolder()
    }

    func windowWillClose(_ notification: Notification) {
        guard action == .cancel else {
            return
        }

        NSApp.stopModal()
    }

    private func finish(_ action: Action) {
        self.action = action
        NSApp.stopModal()
        switch action {
        case .choose, .cancel:
            panel?.close()
        case .open, .up, .refresh, .newFolder:
            break
        }
    }
}

@MainActor
final class RemoteFileStore: ObservableObject {
    private nonisolated static let processLogger = Logger(subsystem: "kucc.co.kr.Ornithopter", category: "FileProcess")
    @Published private(set) var currentPath: String
    @Published private(set) var items: [RemoteFileItem] = [] { didSet { treeRevision &+= 1 } }
    @Published private(set) var childrenByPath: [String: [RemoteFileItem]] = [:] { didSet { treeRevision &+= 1 } }
    @Published private(set) var expandedPaths: Set<String> = []
    @Published private(set) var loadingPaths: Set<String> = []
    @Published private(set) var downloadingPaths: Set<String> = []
    @Published private(set) var uploadingPaths: Set<String> = []
    @Published private(set) var movingPaths: Set<String> = []
    @Published private(set) var selectedPaths: Set<String> = []
    @Published private(set) var copiedItems: [RemoteFileItem] = []
    @Published private(set) var newFolderParent: String? { didSet { treeRevision &+= 1 } }
    private(set) var treeRevision = 0
    private var listingRequests = RemoteListingRequests()
    private var linkQueue: [RemoteFileItem] = []
    private var pendingLinks: Set<String> = []
    private var linksNeedingResolution: Set<String> = []
    private var activeLinkProbes = 0
    private var linkGeneration = UUID()
    @Published private(set) var status = NSLocalizedString("Not loaded", comment: "")
    @Published private(set) var transferPercent: Double?

    static let acceptedDropTypes: [UTType] = [.item, .fileURL]

    private let profile: ServerProfile
    private let sessionPassword: String?
    private let directoryLoader: (@Sendable (String) -> Result<[RemoteFileItem], Error>)?
    private let linkProbe: (@Sendable (String) -> RemoteFileItem.LinkTarget)?

    private var hasActiveFileOperation: Bool {
        !downloadingPaths.isEmpty || !uploadingPaths.isEmpty || !movingPaths.isEmpty
    }

    private nonisolated static func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private nonisolated static func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }

    private nonisolated static func transferStatus(formatKey: String, multiItemFormatKey: String, progress: RemoteTransferProgress) -> String {
        let message: String
        if let itemIndex = progress.itemIndex,
           let itemCount = progress.itemCount,
           itemCount > 1 {
            message = localizedFormat(multiItemFormatKey, itemIndex, itemCount, progress.itemName)
        } else {
            message = localizedFormat(formatKey, progress.itemName)
        }

        return message + " \(progress.percent)%"
    }

    private func showTransferFailureAlert(_ message: String) {
        if message.contains(Self.localized("Permission check cancelled. No files were changed.")) { return }
        let isPermissionFailure = message.contains(Self.localized("Permission check failed. No files were changed."))
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Self.localized(isPermissionFailure ? "Permission Denied" : "File Operation Failed")
        alert.informativeText = isPermissionFailure ? message : Self.localizedFormat("Reason: %@", Self.transferFailureReason(for: message)) + "\n\n" + message
        alert.addButton(withTitle: Self.localized("OK"))
        alert.runModal()
    }

    private nonisolated static func transferFailureReason(for message: String) -> String {
        let lowercasedMessage = message.lowercased()

        if lowercasedMessage.contains("already exists") {
            return localized("An item with the same name already exists")
        }
        if lowercasedMessage.contains("no space left") || lowercasedMessage.contains("disk full") {
            return localized("Not enough disk space")
        }
        if lowercasedMessage.contains("no such file")
            || lowercasedMessage.contains("not found")
            || lowercasedMessage.contains("couldn't stat") {
            return localized("File or folder not found")
        }
        if lowercasedMessage.contains("timed out") || lowercasedMessage.contains("timeout") {
            return localized("Connection timed out")
        }
        if lowercasedMessage.contains("authentication failed")
            || lowercasedMessage.contains("permission denied (publickey")
            || lowercasedMessage.contains("permission denied (password") {
            return localized("Authentication failed")
        }
        if lowercasedMessage.contains("permission denied") {
            return localized("Permission denied")
        }

        return localized("Transfer command failed")
    }

    init(profile: ServerProfile, sessionPassword: String?,
         directoryLoader: (@Sendable (String) -> Result<[RemoteFileItem], Error>)? = nil,
         linkProbe: (@Sendable (String) -> RemoteFileItem.LinkTarget)? = nil) {
        self.directoryLoader = directoryLoader
        self.linkProbe = linkProbe
        self.profile = profile
        self.sessionPassword = sessionPassword
        self.currentPath = "."
    }

    func refresh() {
        refreshPreservingTree()
        reloadExpandedFolders()
    }

    private func refreshPreservingTree() {
        load(path: currentPath, updateCurrentPath: false, resetTree: false)
    }

    private func reloadExpandedFolders() {
        for path in expandedPaths.sorted() where path != currentPath {
            loadChildren(path: path, force: true)
        }
    }

    private func load(path: String, updateCurrentPath: Bool, resetTree: Bool) {
        status = Self.localized("Loading...")
        listingRequests.invalidateAll()
        loadingPaths.removeAll()
        let request = listingRequests.begin(path: path)
        loadingPaths.insert(path)
        linkGeneration = UUID()
        linkQueue.removeAll()
        pendingLinks.removeAll()
        if resetTree {
            expandedPaths.removeAll()
            childrenByPath.removeAll()
        }

        Task.detached { [profile, sessionPassword, directoryLoader] in
            let result = directoryLoader?(path).mapError { RemoteFileError(message: $0.localizedDescription) }
                ?? Self.loadDirectory(profile: profile, path: path, password: sessionPassword)

            await MainActor.run {
                guard self.listingRequests.finish(path: path, request: request) else { return }
                self.loadingPaths.remove(path)
                switch result {
                case .success(let items):
                    if updateCurrentPath {
                        self.currentPath = path
                    }
                    self.applyListing(items, at: path)
                    let visibleCount = self.visibleItems(items).count
                    self.status = visibleCount == 0
                        ? Self.localized("Empty folder")
                        : Self.localizedFormat("%d items", visibleCount)
                case .failure(let error):
                    self.status = "\(path): \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshAfterDelay(seconds: UInt64) async {
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        if items.isEmpty {
            refreshPreservingTree()
        }
    }

    func open(_ item: RemoteFileItem) {
        guard item.isBrowsableDirectory else {
            return
        }

        if expandedPaths.contains(item.path) {
            expandedPaths.remove(item.path)
            return
        }

        expandedPaths.insert(item.path)

        if childrenByPath[item.path] != nil {
            return
        }

        loadChildren(path: item.path)
    }

    func goUp() {
        guard currentPath != "/" && currentPath != "." && currentPath != "~" else {
            return
        }

        let trimmed = currentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed.split(separator: "/").map(String.init)

        if currentPath.hasPrefix("/") {
            currentPath = components.dropLast().isEmpty ? "/" : "/" + components.dropLast().joined(separator: "/")
        } else {
            currentPath = components.dropLast().isEmpty ? "." : components.dropLast().joined(separator: "/")
        }

        refresh()
    }

    func children(for item: RemoteFileItem) -> [RemoteFileItem] {
        visibleItems(childrenByPath[item.path] ?? [])
    }

    func isExpanded(_ item: RemoteFileItem) -> Bool {
        expandedPaths.contains(item.path)
    }

    func isLoading(_ item: RemoteFileItem) -> Bool {
        loadingPaths.contains(item.path)
    }

    func isDownloading(_ item: RemoteFileItem) -> Bool {
        downloadingPaths.contains(item.path)
    }

    func isUploading(to path: String) -> Bool {
        uploadingPaths.contains(path)
    }

    func isMoving(_ item: RemoteFileItem) -> Bool {
        movingPaths.contains(item.path)
    }

    func isSelected(_ item: RemoteFileItem) -> Bool {
        selectedPaths.contains(item.path)
    }

    func isCopied(_ item: RemoteFileItem) -> Bool {
        copiedItems.contains { $0.path == item.path }
    }

    var hasCopiedItems: Bool {
        !copiedItems.isEmpty
    }

    var hasMultipleSelection: Bool {
        selectedPaths.count > 1
    }

    func serverTransferTargets(from profiles: [ServerProfile]) -> [ServerProfile] {
        profiles
            .filter { $0.id != profile.id && !$0.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func isCreatingFolder(in path: String) -> Bool {
        newFolderParent == path
    }

    func uploadTarget(for item: RemoteFileItem) -> String {
        item.isBrowsableDirectory ? item.path : Self.parentPath(item.path)
    }

    func select(_ item: RemoteFileItem, extending: Bool) {
        if extending {
            if selectedPaths.contains(item.path) {
                selectedPaths.remove(item.path)
            } else {
                selectedPaths.insert(item.path)
            }
        } else {
            selectedPaths.removeAll()
            selectedPaths.insert(item.path)
        }
    }

    func setSelection(_ paths: Set<String>) {
        if selectedPaths != paths { selectedPaths = paths }
    }

    func resolveVisibleLink(_ item: RemoteFileItem) {
        let parent = Self.parentPath(item.path)
        let current = (childrenByPath[parent] ?? items).first { $0.path == item.path }
        guard let current, current.kind == .symbolicLink,
              current.linkTarget == .unresolved || linksNeedingResolution.contains(current.path),
              pendingLinks.insert(current.path).inserted else { return }
        linkQueue.append(current)
        startLinkProbes()
    }

    private func applyListing(_ incoming: [RemoteFileItem], at path: String) {
        let previous = childrenByPath[path] ?? (path == currentPath ? items : [])
        let previousByPath = Dictionary(previous.map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })
        let possibleDirectories = Set(incoming.filter { $0.isDirectory || $0.kind == .symbolicLink }.map(\.path))
        for removed in previous where (removed.isDirectory || removed.kind == .symbolicLink) && !possibleDirectories.contains(removed.path) {
            let isRemoved: (String) -> Bool = { $0 == removed.path || $0.hasPrefix(removed.path + "/") }
            listingRequests.invalidateSubtree(removed.path)
            childrenByPath = childrenByPath.filter { !isRemoved($0.key) }
            expandedPaths = expandedPaths.filter { !isRemoved($0) }
            loadingPaths = loadingPaths.filter { !isRemoved($0) }
            linksNeedingResolution = linksNeedingResolution.filter { !isRemoved($0) }
        }
        let published = incoming.map { item -> RemoteFileItem in
            guard item.kind == .symbolicLink else { return item }
            linksNeedingResolution.insert(item.path)
            var value = item
            if let old = previousByPath[item.path], old.kind == .symbolicLink {
                // Keep the existing presentation while the refreshed target is
                // checked, avoiding a collapse/selection loss on every refresh.
                value.linkTarget = old.linkTarget
            }
            return value
        }
        if path == currentPath { items = published }
        childrenByPath[path] = published
    }

    private func startLinkProbes() {
        while activeLinkProbes < 2, !linkQueue.isEmpty {
            let item = linkQueue.removeFirst()
            let generation = linkGeneration
            let parent = Self.parentPath(item.path)
            let version = listingRequests.version(path: parent)
            activeLinkProbes += 1
            Task.detached { [profile, sessionPassword, linkProbe] in
                let target = linkProbe?(item.path) ?? Self.probeDirectoryLink(item.path, profile: profile, password: sessionPassword)
                await MainActor.run {
                    self.activeLinkProbes -= 1
                    defer { self.startLinkProbes() }
                    guard generation == self.linkGeneration else { return }
                    self.pendingLinks.remove(item.path)
                    guard version == self.listingRequests.version(path: parent) else { return }
                    self.linksNeedingResolution.remove(item.path)
                    var resolved = item
                    resolved.linkTarget = target
                    if let index = self.items.firstIndex(of: item) { self.items[index] = resolved }
                    if let index = self.childrenByPath[parent]?.firstIndex(of: item) {
                        self.childrenByPath[parent]?[index] = resolved
                    }
                }
            }
        }
    }

    private nonisolated static func probeDirectoryLink(_ path: String, profile: ServerProfile, password: String?) -> RemoteFileItem.LinkTarget {
        switch runSFTPProcess(input: "cd \(sftpQuoted(path))\nquit\n", profile: profile, password: password, timeoutMessage: localized("SFTP timed out")) {
        case .success(let result):
            if result.terminationStatus == 0 { return .directory }
            if result.errorText.lowercased().contains("not a directory") { return .nonDirectory }
            return .unavailable
        case .failure: return .unavailable
        }
    }

    func clearSelection() {
        selectedPaths.removeAll()
    }

    func actionItems(for item: RemoteFileItem) -> [RemoteFileItem] {
        if selectedPaths.contains(item.path) {
            let selected = knownItems().filter { selectedPaths.contains($0.path) }
            if !selected.isEmpty {
                return selected
            }
        }

        return [item]
    }

    func dragItems(for item: RemoteFileItem) -> [RemoteFileItem] {
        let items = actionItems(for: item)
        if items.contains(where: { $0.path == item.path }) {
            return items
        }

        return [item]
    }

    func copy(_ item: RemoteFileItem) {
        copy(actionItems(for: item))
    }

    func copy(_ items: [RemoteFileItem]) {
        copiedItems = uniqueItems(items)
        status = copiedItems.count == 1
            ? Self.localizedFormat("Copied %@", copiedItems[0].name)
            : Self.localizedFormat("Copied %d items", copiedItems.count)
    }

    func paste(to remoteDirectory: String) {
        let itemsToPaste = copiedItems
        guard !itemsToPaste.isEmpty else {
            status = Self.localized("Nothing to paste")
            return
        }

        let destinationDirectory = remoteDirectory
        if itemsToPaste.contains(where: { $0.isDirectory && (destinationDirectory == $0.path || destinationDirectory.hasPrefix($0.path + "/")) }) {
            status = Self.localized("Cannot copy a folder into itself.")
            return
        }

        uploadingPaths.insert(destinationDirectory)
        status = itemsToPaste.count == 1
            ? Self.localizedFormat("Copying %@...", itemsToPaste[0].name)
            : Self.localizedFormat("Copying %d items...", itemsToPaste.count)

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: destinationDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                let copiedNames = itemsToPaste.map(\.name)
                if let duplicateName = Self.firstDuplicateName(copiedNames) {
                    result = .failure(RemoteFileError(message: Self.localizedFormat("Multiple copied items are named %@.", duplicateName)))
                } else if let existingName = copiedNames.first(where: { name in remoteItems.contains { $0.name == name } }) {
                    result = .failure(RemoteFileError(message: Self.localizedFormat("An item named %@ already exists.", existingName)))
                } else {
                    result = Self.copyItems(itemsToPaste, to: destinationDirectory, profile: profile, password: sessionPassword)
                }
            case .failure(let error):
                result = .failure(error)
            }

            await MainActor.run {
                self.uploadingPaths.remove(destinationDirectory)

                switch result {
                case .success:
                    self.status = itemsToPaste.count == 1
                        ? Self.localizedFormat("Pasted %@", itemsToPaste[0].name)
                        : Self.localizedFormat("Pasted %d items", itemsToPaste.count)
                    self.reloadAfterUpload(to: destinationDirectory)
                case .failure(let error):
                    let message = "\(destinationDirectory): \(error.localizedDescription)"
                    self.status = message
                    self.showTransferFailureAlert(message)
                }
            }
        }
    }

    func newFolder(in remoteDirectory: String) {
        newFolderParent = remoteDirectory

        guard remoteDirectory != currentPath else {
            return
        }

        expandedPaths.insert(remoteDirectory)
        if childrenByPath[remoteDirectory] == nil {
            loadChildren(path: remoteDirectory)
        }
    }

    func cancelNewFolder() {
        newFolderParent = nil
    }

    func createFolder(named proposedName: String, in remoteDirectory: String) -> Bool {
        let validation = validateName(proposedName, in: remoteDirectory, excluding: nil)
        guard validation.isValid, let name = validation.name else {
            status = validation.message ?? Self.localized("Invalid folder name")
            return false
        }

        uploadingPaths.insert(remoteDirectory)
        status = Self.localizedFormat("Creating %@...", name)

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: remoteDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                if remoteItems.contains(where: { $0.name == name }) {
                    result = .failure(RemoteFileError(message: Self.localizedFormat("An item named %@ already exists.", name)))
                } else {
                    let newPath = Self.joined(remoteDirectory, name)
                    result = Self.makeDirectory(newPath, profile: profile, password: sessionPassword)
                }
            case .failure(let error):
                result = .failure(error)
            }

            await MainActor.run {
                self.uploadingPaths.remove(remoteDirectory)

                switch result {
                case .success:
                    if self.newFolderParent == remoteDirectory {
                        self.newFolderParent = nil
                    }
                    self.status = Self.localizedFormat("Created %@", name)
                    self.reloadAfterUpload(to: remoteDirectory)
                case .failure(let error):
                    self.status = "\(name): \(error.localizedDescription)"
                }
            }
        }

        return true
    }

    func rename(_ item: RemoteFileItem, to proposedName: String) -> Bool {
        let validation = validateName(proposedName, in: Self.parentPath(item.path), excluding: item)
        guard validation.isValid, let newName = validation.name else {
            status = validation.message ?? Self.localized("Invalid name")
            return false
        }

        guard newName != item.name else {
            return true
        }

        let newPath = Self.joined(Self.parentPath(item.path), newName)
        status = Self.localizedFormat("Renaming %@...", item.name)

        Task.detached { [profile, sessionPassword] in
            let result = Self.renameItem(item, to: newPath, profile: profile, password: sessionPassword)

            await MainActor.run {
                switch result {
                case .success:
                    self.status = Self.localizedFormat("Renamed %@ to %@", item.name, newName)
                    self.reloadParent(of: item)
                case .failure(let error):
                    self.status = "\(item.name): \(error.localizedDescription)"
                }
            }
        }

        return true
    }

    func delete(_ item: RemoteFileItem) {
        delete(actionItems(for: item))
    }

    func delete(_ items: [RemoteFileItem]) {
        guard !hasActiveFileOperation else { return }
        let itemsToDelete = uniqueItems(items)
        guard !itemsToDelete.isEmpty, confirmDelete(itemsToDelete) else {
            return
        }

        for item in itemsToDelete {
            movingPaths.insert(item.path)
        }
        status = Self.localized("Checking permissions...")

        Task.detached { [profile, sessionPassword] in
            let result = Self.deleteItems(itemsToDelete, profile: profile, password: sessionPassword)

            await MainActor.run {
                for item in itemsToDelete {
                    self.movingPaths.remove(item.path)
                }

                switch result {
                case .success:
                    for item in itemsToDelete {
                        self.expandedPaths.remove(item.path)
                        self.childrenByPath.removeValue(forKey: item.path)
                        self.selectedPaths.remove(item.path)
                    }
                    self.status = itemsToDelete.count == 1
                        ? Self.localizedFormat("Deleted %@", itemsToDelete[0].name)
                        : Self.localizedFormat("Deleted %d items", itemsToDelete.count)
                    self.reloadParents(of: itemsToDelete)
                case .failure(let error):
                    self.status = error.localizedDescription
                    self.reloadParents(of: itemsToDelete)
                    self.showTransferFailureAlert(error.localizedDescription)
                }
            }
        }
    }

    func download(_ item: RemoteFileItem) {
        let selectedItems = actionItems(for: item)
        guard selectedItems.count > 1 else {
            downloadSingle(item)
            return
        }

        download(selectedItems)
    }

    private func downloadSingle(_ item: RemoteFileItem) {
        guard !hasActiveFileOperation else { return }
        guard let destination = askDownloadDestination(for: item) else {
            return
        }

        downloadingPaths.insert(item.path)
        transferPercent = nil
        status = Self.localized("Checking permissions...")

        Task.detached { [profile, sessionPassword] in
            let result = Self.downloadItem(
                item,
                to: destination,
                profile: profile,
                password: sessionPassword
            ) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadingPaths.contains(item.path) else {
                        return
                    }

                    self.transferPercent = Double(progress.percent) / 100
                    self.status = Self.transferStatus(
                        formatKey: "Downloading %@...",
                        multiItemFormatKey: "Downloading %d/%d %@...",
                        progress: progress
                    )
                }
            }

            await MainActor.run {
                self.downloadingPaths.remove(item.path)
                self.transferPercent = nil

                switch result {
                case .success:
                    self.status = Self.localizedFormat("Downloaded %@", item.name)
                case .failure(let error):
                    let message = "\(item.name): \(error.localizedDescription)"
                    self.status = message
                    self.showTransferFailureAlert(message)
                }
            }
        }
    }

    func download(_ items: [RemoteFileItem]) {
        guard !hasActiveFileOperation else { return }
        let itemsToDownload = uniqueItems(items)
        guard !itemsToDownload.isEmpty,
              let destination = askDownloadDirectory() else {
            return
        }

        for item in itemsToDownload {
            downloadingPaths.insert(item.path)
        }
        transferPercent = nil
        status = Self.localized("Checking permissions...")

        Task.detached { [profile, sessionPassword] in
            let result = Self.downloadItems(
                itemsToDownload,
                toDirectory: destination,
                profile: profile,
                password: sessionPassword
            ) { progress in
                Task { @MainActor [weak self] in
                    guard let self,
                          itemsToDownload.contains(where: { self.downloadingPaths.contains($0.path) }) else {
                        return
                    }

                    self.transferPercent = Double(progress.percent) / 100
                    self.status = Self.transferStatus(
                        formatKey: "Downloading %@...",
                        multiItemFormatKey: "Downloading %d/%d %@...",
                        progress: progress
                    )
                }
            }

            await MainActor.run {
                for item in itemsToDownload {
                    self.downloadingPaths.remove(item.path)
                }
                self.transferPercent = nil

                switch result {
                case .success:
                    self.status = Self.localizedFormat("Downloaded %d items", itemsToDownload.count)
                case .failure(let error):
                    let message = error.localizedDescription
                    self.status = message
                    self.showTransferFailureAlert(message)
                }
            }
        }
    }

    func makeFilePromise(for item: RemoteFileItem) -> RemoteFilePromiseProvider? {
        guard !hasActiveFileOperation else { return nil }
        let items = dragItems(for: item)
        let provider = dragItemProvider(for: item)
        guard let token = AppDragRegistry.activeRemoteFilePayload?.token else { return nil }
        return RemoteFilePromiseProvider(provider: provider, token: token,
                                         name: items.count > 1 ? "Ornithopter Selection" : item.name,
                                         typeIdentifier: Self.dragTypeIdentifier(for: items, draggedItem: item))
    }

    func dragItemProvider(for item: RemoteFileItem) -> NSItemProvider {
        let provider = NSItemProvider()
        guard !hasActiveFileOperation else { return provider }
        let items = dragItems(for: item)
        provider.suggestedName = Self.dragSuggestedName(for: items, draggedItem: item)
        let token = AppDragRegistry.beginRemoteFileDrag(
            payload: RemoteFileDragPayload(
                profile: profile,
                sessionPassword: sessionPassword,
                items: items
            )
        )

        let typeIdentifier = Self.dragTypeIdentifier(for: items, draggedItem: item)

        provider.registerFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { [profile, sessionPassword, store = self] completion in
            let providerProgress = Progress(totalUnitCount: 100)

            Task { @MainActor [weak store] in
                guard let store else {
                    return
                }

                for item in items {
                    store.downloadingPaths.insert(item.path)
                }
                store.transferPercent = nil
                store.status = items.count == 1
                    ? Self.localizedFormat("Downloading %@...", items[0].name)
                    : Self.localizedFormat("Downloading %d items...", items.count)
            }

            Task.detached { [store] in
                let destination = Self.temporaryDragDestination(for: items, draggedItem: item)
                try? FileManager.default.removeItem(at: destination)

                let result = Self.downloadDragItems(
                    items,
                    to: destination,
                    profile: profile,
                    password: sessionPassword
                ) { progress in
                    providerProgress.completedUnitCount = Int64(progress.percent)

                    Task { @MainActor [store] in
                        guard items.contains(where: { store.downloadingPaths.contains($0.path) }) else {
                            return
                        }

                        store.transferPercent = Double(progress.percent) / 100
                        store.status = Self.transferStatus(
                            formatKey: "Downloading %@...",
                            multiItemFormatKey: "Downloading %d/%d %@...",
                            progress: progress
                        )
                    }
                }

                switch result {
                case .success:
                    providerProgress.completedUnitCount = 100
                    completion(destination, false, nil)
                case .failure(let error):
                    completion(nil, false, error)
                }

                Task { @MainActor [store] in
                    for item in items {
                        store.downloadingPaths.remove(item.path)
                    }
                    store.transferPercent = nil
                    switch result {
                    case .success:
                        store.status = items.count == 1
                            ? Self.localizedFormat("Downloaded %@", items[0].name)
                            : Self.localizedFormat("Downloaded %d items", items.count)
                    case .failure(let error):
                        let message = error.localizedDescription
                        store.status = message
                        store.showTransferFailureAlert(message)
                    }
                    AppDragRegistry.clearActiveRemoteFileDrag(token)
                }
            }

            return providerProgress
        }

        return provider
    }

    func chooseAndUpload(to remoteDirectory: String) {
        guard let urls = askUploadSources(), !urls.isEmpty else {
            return
        }

        upload(urls, to: remoteDirectory)
    }

    func uploadDroppedURLs(_ urls: [URL], to remoteDirectory: String) {
        upload(urls, to: remoteDirectory)
    }

    func remoteDragOperation(token: UUID) -> NSDragOperation {
        guard let payload = AppDragRegistry.remoteFilePayload(for: token) else { return [] }
        return payload.profile.id == profile.id ? .move : .copy
    }

    func handleRemoteFileDrop(token: UUID, to remoteDirectory: String) -> Bool {
        guard let payload = AppDragRegistry.remoteFilePayload(for: token) else { return false }
        handleRemoteFileDrop(token: token, payload: payload, to: remoteDirectory)
        return true
    }

    func handleActiveRemoteFileDrop(to remoteDirectory: String) -> Bool {
        guard let activeDrag = AppDragRegistry.activeRemoteFilePayload else {
            return false
        }

        handleRemoteFileDrop(token: activeDrag.token, payload: activeDrag.payload, to: remoteDirectory)
        return true
    }

    func handleDropProviders(_ providers: [NSItemProvider], to remoteDirectory: String) -> Bool {
        if AppDragRegistry.activeRemoteFilePayload != nil {
            return handleActiveRemoteFileDrop(to: remoteDirectory)
        }

        let localFileProviders = providers.filter(Self.canLoadLocalFileURL)

        guard !localFileProviders.isEmpty else {
            return false
        }

        for provider in localFileProviders {
            Self.loadLocalFileURL(from: provider) { url in
                guard let url else {
                    return
                }

                Task { @MainActor in
                    self.upload([url], to: remoteDirectory)
                }
            }
        }

        return true
    }

    private nonisolated static func canLoadLocalFileURL(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.canLoadObject(ofClass: NSURL.self)
    }

    private nonisolated static func loadLocalFileURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        if provider.canLoadObject(ofClass: NSURL.self) {
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                completion((object as? URL) ?? (object as? NSURL).map { $0 as URL })
            }
            return
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            completion(fileURL(from: item))
        }
    }

    private func handleRemoteFileDrop(token: UUID, payload dragContext: RemoteFileDragPayload, to remoteDirectory: String) {
        AppDragRegistry.endRemoteFileDrag(token)

        if dragContext.profile.id == profile.id {
            move(dragContext.items, to: remoteDirectory)
        } else {
            copyFromRemote(dragContext, to: remoteDirectory)
        }
    }

    func copyToServer(_ item: RemoteFileItem, targetProfile: ServerProfile) {
        let itemsToCopy = uniqueItems(actionItems(for: item))
        guard !itemsToCopy.isEmpty else {
            return
        }

        guard let passwordResult = SSHPasswordPrompter.passwordForConnection(profile: targetProfile) else {
            return
        }

        guard let remoteDirectory = askRemoteDirectory(profile: targetProfile, password: passwordResult.password) else {
            return
        }

        copyItemsToServer(
            itemsToCopy,
            targetProfile: targetProfile,
            targetPassword: passwordResult.password,
            remoteDirectory: remoteDirectory
        )
    }

    private func copyFromRemote(_ context: RemoteFileDragPayload, to remoteDirectory: String) {
        let itemsToCopy = uniqueItems(context.items)
        guard !itemsToCopy.isEmpty else {
            return
        }

        copyItemsToServer(
            itemsToCopy,
            sourceProfile: context.profile,
            sourcePassword: context.sessionPassword,
            targetProfile: profile,
            targetPassword: sessionPassword,
            remoteDirectory: remoteDirectory,
            reloadTargetDirectory: true
        )
    }

    private func copyItemsToServer(
        _ itemsToCopy: [RemoteFileItem],
        sourceProfile: ServerProfile? = nil,
        sourcePassword: String? = nil,
        targetProfile: ServerProfile,
        targetPassword: String?,
        remoteDirectory: String,
        reloadTargetDirectory: Bool = false
    ) {
        guard !hasActiveFileOperation, !itemsToCopy.isEmpty else { return }
        let sourceProfile = sourceProfile ?? profile
        let sourcePassword = sourcePassword ?? sessionPassword
        let remoteDirectory = Self.normalizedRemoteBrowserPath(remoteDirectory)

        uploadingPaths.insert(remoteDirectory)
        transferPercent = nil
        status = itemsToCopy.count == 1
            ? Self.localizedFormat("Copying %@...", itemsToCopy[0].name)
            : Self.localizedFormat("Copying %d items...", itemsToCopy.count)

        Task.detached { [currentProfile = profile] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: targetProfile, path: remoteDirectory, password: targetPassword) {
            case .success(let remoteItems):
                let itemNames = itemsToCopy.map(\.name)
                if let duplicateName = Self.firstDuplicateName(itemNames) {
                    result = .failure(RemoteFileError(message: Self.localizedFormat("Multiple copied items are named %@.", duplicateName)))
                } else if let existingName = itemNames.first(where: { name in remoteItems.contains { $0.name == name } }) {
                    result = .failure(RemoteFileError(message: Self.localizedFormat("An item named %@ already exists.", existingName)))
                } else {
                    result = Self.copyItemsBetweenServers(
                        itemsToCopy,
                        from: sourceProfile,
                        sourcePassword: sourcePassword,
                        to: remoteDirectory,
                        targetProfile: targetProfile,
                        targetPassword: targetPassword
                    ) { progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.uploadingPaths.contains(remoteDirectory) else {
                                return
                            }

                            self.transferPercent = Double(progress.percent) / 100
                            self.status = Self.transferStatus(
                                formatKey: "Copying %@...",
                                multiItemFormatKey: "Copying %d/%d %@...",
                                progress: progress
                            )
                        }
                    }
                }
            case .failure(let error):
                result = .failure(error)
            }

            await MainActor.run {
                self.uploadingPaths.remove(remoteDirectory)
                self.transferPercent = nil

                switch result {
                case .success:
                    self.status = itemsToCopy.count == 1
                        ? Self.localizedFormat("Copied %@", itemsToCopy[0].name)
                        : Self.localizedFormat("Copied %d items", itemsToCopy.count)
                    if reloadTargetDirectory && targetProfile.id == currentProfile.id {
                        self.reloadAfterUpload(to: remoteDirectory)
                    }
                case .failure(let error):
                    let message = error.localizedDescription
                    self.status = message
                    if reloadTargetDirectory && targetProfile.id == currentProfile.id {
                        self.reloadAfterUpload(to: remoteDirectory)
                    }
                    self.showTransferFailureAlert(message)
                }
            }
        }
    }

    private func move(_ item: RemoteFileItem, to remoteDirectory: String) {
        move([item], to: remoteDirectory)
    }

    private func move(_ items: [RemoteFileItem], to remoteDirectory: String) {
        guard !hasActiveFileOperation else { return }
        let itemsToMove = uniqueItems(items)
        let destinationDirectory = remoteDirectory
        guard !itemsToMove.isEmpty else {
            return
        }

        if itemsToMove.allSatisfy({ Self.parentPath($0.path) == destinationDirectory }) {
            status = itemsToMove.count == 1
                ? Self.localizedFormat("%@ is already in this folder", itemsToMove[0].name)
                : Self.localized("Selected items are already in this folder")
            return
        }

        if itemsToMove.contains(where: { $0.isDirectory && (destinationDirectory == $0.path || destinationDirectory.hasPrefix($0.path + "/")) }) {
            status = Self.localized("Cannot move a folder into itself.")
            return
        }

        for item in itemsToMove {
            movingPaths.insert(item.path)
        }
        status = itemsToMove.count == 1
            ? Self.localizedFormat("Moving %@...", itemsToMove[0].name)
            : Self.localizedFormat("Moving %d items...", itemsToMove.count)

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: destinationDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                let itemNames = itemsToMove.map(\.name)
                if let duplicateName = Self.firstDuplicateName(itemNames) {
                    result = .failure(RemoteFileError(message: Self.localizedFormat("Multiple selected items are named %@.", duplicateName)))
                } else if let existingName = itemNames.first(where: { name in remoteItems.contains { $0.name == name } }) {
                    result = .failure(RemoteFileError(message: Self.localizedFormat("An item named %@ already exists.", existingName)))
                } else {
                    result = Self.renameItems(itemsToMove, to: destinationDirectory, profile: profile, password: sessionPassword)
                }
            case .failure(let error):
                result = .failure(error)
            }

            await MainActor.run {
                for item in itemsToMove {
                    self.movingPaths.remove(item.path)
                }

                switch result {
                case .success:
                    self.status = itemsToMove.count == 1
                        ? Self.localizedFormat("Moved %@", itemsToMove[0].name)
                        : Self.localizedFormat("Moved %d items", itemsToMove.count)
                    self.reloadParents(of: itemsToMove)
                    if self.expandedPaths.contains(destinationDirectory) || destinationDirectory == self.currentPath {
                        self.reloadAfterUpload(to: destinationDirectory)
                    }
                case .failure(let error):
                    self.status = error.localizedDescription
                    self.reloadParents(of: itemsToMove)
                    self.reloadAfterUpload(to: destinationDirectory)
                    self.showTransferFailureAlert(error.localizedDescription)
                }
            }
        }
    }

    private func upload(_ urls: [URL], to remoteDirectory: String) {
        guard !hasActiveFileOperation else { return }
        if let message = Self.validateUploadSources(urls).message {
            status = message
            return
        }

        uploadingPaths.insert(remoteDirectory)
        transferPercent = nil
        status = Self.localized("Checking permissions...")

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: remoteDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                if let message = Self.validateUploadSources(urls, existingItems: remoteItems).message {
                    result = .failure(RemoteFileError(message: message))
                } else {
                    result = Self.uploadItems(
                        urls,
                        to: remoteDirectory,
                        profile: profile,
                        password: sessionPassword
                    ) { progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.uploadingPaths.contains(remoteDirectory) else {
                                return
                            }

                            self.transferPercent = Double(progress.percent) / 100
                            self.status = Self.transferStatus(
                                formatKey: "Uploading %@...",
                                multiItemFormatKey: "Uploading %d/%d %@...",
                                progress: progress
                            )
                        }
                    }
                }
            case .failure(let error):
                result = .failure(error)
            }

            await MainActor.run {
                self.uploadingPaths.remove(remoteDirectory)
                self.transferPercent = nil

                switch result {
                case .success:
                    self.status = urls.count == 1
                        ? Self.localizedFormat("Uploaded %@", urls[0].lastPathComponent)
                        : Self.localizedFormat("Uploaded %d items", urls.count)
                    self.reloadAfterUpload(to: remoteDirectory)
                case .failure(let error):
                    let message = "\(remoteDirectory): \(error.localizedDescription)"
                    self.status = message
                    self.reloadAfterUpload(to: remoteDirectory)
                    self.showTransferFailureAlert(message)
                }
            }
        }
    }

    private func validateName(_ proposedName: String, in parentPath: String, excluding item: RemoteFileItem?) -> NameValidation {
        let validation = Self.validateRemoteName(proposedName)
        guard validation.isValid, let name = validation.name else {
            return validation
        }

        let siblings = childrenByPath[parentPath] ?? (parentPath == currentPath ? items : [])
        if siblings.contains(where: { $0.path != item?.path && $0.name == name }) {
            return NameValidation(name: name, message: Self.localizedFormat("An item named %@ already exists.", name))
        }

        return NameValidation(name: name, message: nil)
    }

    func visibleItems(_ items: [RemoteFileItem]) -> [RemoteFileItem] {
        guard profile.hideHiddenFiles else {
            return items
        }

        return items.filter { !$0.isHidden }
    }

    private func reloadAfterUpload(to remoteDirectory: String) {
        if remoteDirectory == currentPath {
            refresh()
        } else if expandedPaths.contains(remoteDirectory) {
            loadChildren(path: remoteDirectory, force: true)
        }
    }

    private func reloadParent(of item: RemoteFileItem) {
        let parent = Self.parentPath(item.path)
        if parent == currentPath {
            refresh()
        } else if expandedPaths.contains(parent) {
            loadChildren(path: parent, force: true)
        } else {
            refresh()
        }
    }

    private func reloadParents(of items: [RemoteFileItem]) {
        let parents = Set(items.map { Self.parentPath($0.path) })
        if parents.contains(currentPath) {
            refresh()
            return
        }

        var didReloadExpandedParent = false
        for parent in parents where expandedPaths.contains(parent) {
            didReloadExpandedParent = true
            loadChildren(path: parent, force: true)
        }

        if !didReloadExpandedParent {
            refresh()
        }
    }

    private func uniqueItems(_ items: [RemoteFileItem]) -> [RemoteFileItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard !seen.contains(item.path) else {
                return false
            }

            seen.insert(item.path)
            return true
        }
    }

    private func knownItems() -> [RemoteFileItem] {
        var result = items
        for children in childrenByPath.values {
            result.append(contentsOf: children)
        }
        return uniqueItems(result)
    }

    private func loadChildren(path: String, force: Bool = false) {
        guard force || !loadingPaths.contains(path) else { return }
        let request = listingRequests.begin(path: path)
        loadingPaths.insert(path)
        status = Self.localizedFormat("Loading %@...", path)

        Task.detached { [profile, sessionPassword, directoryLoader] in
            let result = directoryLoader?(path).mapError { RemoteFileError(message: $0.localizedDescription) }
                ?? Self.loadDirectory(profile: profile, path: path, password: sessionPassword)

            await MainActor.run {
                guard self.listingRequests.finish(path: path, request: request) else { return }
                self.loadingPaths.remove(path)

                switch result {
                case .success(let items):
                    self.applyListing(items, at: path)
                    let visibleCount = self.visibleItems(items).count
                    self.status = visibleCount == 0
                        ? Self.localizedFormat("%@: Empty folder", path)
                        : Self.localizedFormat("%@: %d items", path, visibleCount)
                case .failure(let error):
                    if self.childrenByPath[path] == nil { self.expandedPaths.remove(path) }
                    self.status = "\(path): \(error.localizedDescription)"
                }
            }
        }
    }

    private nonisolated static func loadDirectory(profile: ServerProfile, path: String, password: String?) -> Result<[RemoteFileItem], RemoteFileError> {
        let result = runSFTPProcess(
            input: sftpListCommands(for: path),
            profile: profile,
            password: password,
            timeoutMessage: localized("SFTP timed out")
        )

        switch result {
        case .success(let subprocessResult):
            if subprocessResult.terminationStatus == 0 {
                do {
                    return .success(try RemoteDirectoryListing.parse(subprocessResult.outputText, basePath: path))
                } catch {
                    return .failure(RemoteFileError(message: error.localizedDescription))
                }
            } else {
                return .failure(RemoteFileError(message: subprocessResult.errorText.isEmpty ? localized("SFTP list failed") : subprocessResult.errorText))
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func downloadItem(
        _ item: RemoteFileItem,
        to destination: URL,
        profile: ServerProfile,
        password: String?,
        progress: (@Sendable (RemoteTransferProgress) -> Void)? = nil
    ) -> Result<Void, RemoteFileError> {
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        if case .failure(let error) = checkDownloadDestinations([item], destinations: [destination], profile: profile, password: password) { return .failure(error) }
        if case .failure(let error) = checkRemotePermissions([.init(path: item.path, access: .read)], profile: profile, password: password) {
            return .failure(error)
        }

        if isRsyncAvailable {
            let transferUnitCount = item.isDirectory
                ? remoteTransferUnitCount(for: item, profile: profile, password: password)
                : 1
            switch downloadItemWithRsync(
                item,
                to: destination,
                profile: profile,
                password: password,
                transferUnitCount: transferUnitCount > 1 ? transferUnitCount : nil,
                progress: progress
            ) {
            case .success:
                return .success(())
            case .failure(let error) where shouldFallbackFromRsync(error):
                break
            case .failure(let error):
                return .failure(error)
            }
        }

        return downloadItemWithSFTP(item, to: destination, profile: profile, password: password)
    }

    private nonisolated static func downloadItemWithSFTP(_ item: RemoteFileItem, to destination: URL, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        let command = item.isDirectory
            ? "get -R \(sftpQuoted(item.path)) \(sftpQuoted(destination.path))"
            : "get \(sftpQuoted(item.path)) \(sftpQuoted(destination.path))"
        let commands = """
        \(command)
        quit
        """

        switch runSFTPProcess(
            input: commands,
            profile: profile,
            password: password,
            timeoutMessage: localized("SFTP download timed out")
        ) {
        case .success(let result):
            guard result.terminationStatus == 0 else {
                let message = [result.errorText, result.outputText]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(RemoteFileError(message: message.isEmpty ? "SFTP download failed" : message))
            }
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func downloadItems(
        _ items: [RemoteFileItem],
        toDirectory destination: URL,
        profile: ServerProfile,
        password: String?,
        progress: (@Sendable (RemoteTransferProgress) -> Void)? = nil
    ) -> Result<Void, RemoteFileError> {
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        if case .failure(let error) = checkDownloadDestinations(items, destinations: items.map { destination.appendingPathComponent($0.name) }, profile: profile, password: password) { return .failure(error) }
        if case .failure(let error) = checkRemotePermissions(items.map { .init(path: $0.path, access: .read) }, profile: profile, password: password) {
            return .failure(error)
        }

        if isRsyncAvailable {
            let transferUnitCounts = items.map { remoteTransferUnitCount(for: $0, profile: profile, password: password) }
            let totalTransferUnitCount = transferUnitCounts.reduce(0, +)
            var completedTransferUnitCount = 0

            for (index, item) in items.enumerated() {
                let transferUnitCount = transferUnitCounts[index]
                switch downloadItemToDirectoryWithRsync(
                    item,
                    toDirectory: destination,
                    profile: profile,
                    password: password,
                    itemIndex: index + 1,
                    itemCount: items.count,
                    itemOffset: totalTransferUnitCount > 1 ? completedTransferUnitCount : nil,
                    transferUnitCount: totalTransferUnitCount > 1 ? totalTransferUnitCount : nil,
                    progress: progress
                ) {
                case .success:
                    completedTransferUnitCount += transferUnitCount
                    continue
                case .failure(let error) where shouldFallbackFromRsync(error):
                    return downloadItemsWithSFTP(
                        Array(items.dropFirst(index)),
                        toDirectory: destination,
                        profile: profile,
                        password: password
                    )
                case .failure(let error):
                    return .failure(partialOperationError(error, names: items.map(\.name), failedIndex: index))
                }
            }

            return .success(())
        }

        return downloadItemsWithSFTP(items, toDirectory: destination, profile: profile, password: password)
    }

    private nonisolated static func downloadItemsWithSFTP(_ items: [RemoteFileItem], toDirectory destination: URL, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        performItems(items, names: items.map(\.name)) { item in
            let option = item.isDirectory ? "-R " : ""
            let command = "get \(option)\(sftpQuoted(item.path)) \(sftpQuoted(destination.path))"
            return runSFTPCommands(command, profile: profile, password: password, fallbackMessage: "SFTP download failed")
        }
    }

    private nonisolated static func downloadDragItems(
        _ items: [RemoteFileItem],
        to destination: URL,
        profile: ServerProfile,
        password: String?,
        progress: (@Sendable (RemoteTransferProgress) -> Void)? = nil
    ) -> Result<Void, RemoteFileError> {
        guard items.count > 1 else {
            guard let item = items.first else {
                return .failure(RemoteFileError(message: localized("Nothing to download")))
            }

            return downloadItem(item, to: destination, profile: profile, password: password, progress: progress)
        }

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return .failure(RemoteFileError(message: error.localizedDescription))
        }

        return downloadItems(items, toDirectory: destination, profile: profile, password: password, progress: progress)
    }

    private nonisolated static func uploadItems(
        _ urls: [URL],
        to remoteDirectory: String,
        profile: ServerProfile,
        password: String?,
        progress: (@Sendable (RemoteTransferProgress) -> Void)? = nil
    ) -> Result<Void, RemoteFileError> {
        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        }

        let localIssues = FilePermissionPreflight.localReadIssues(urls)
        if !localIssues.isEmpty { return .failure(RemoteFileError(message: FilePermissionPreflight.message(localIssues))) }
        let requests: [FilePermissionPreflight.Request] = [.init(path: remoteDirectory, access: .directory)] + urls.map { .init(path: joined(remoteDirectory, $0.lastPathComponent), access: .write) }
        if case .failure(let error) = checkRemotePermissions(requests, profile: profile, password: password) {
            return .failure(error)
        }

        if isRsyncAvailable {
            let transferUnitCounts = urls.map { transferUnitCount(for: $0) }
            let totalTransferUnitCount = transferUnitCounts.reduce(0, +)
            var completedTransferUnitCount = 0

            for (index, url) in urls.enumerated() {
                let transferUnitCount = transferUnitCounts[index]
                switch uploadItemWithRsync(
                    url,
                    to: remoteDirectory,
                    profile: profile,
                    password: password,
                    itemIndex: index + 1,
                    itemCount: urls.count,
                    itemOffset: totalTransferUnitCount > 1 ? completedTransferUnitCount : nil,
                    transferUnitCount: totalTransferUnitCount > 1 ? totalTransferUnitCount : nil,
                    progress: progress
                ) {
                case .success:
                    completedTransferUnitCount += transferUnitCount
                    continue
                case .failure(let error) where shouldFallbackFromRsync(error):
                    return uploadItemsWithSFTP(
                        Array(urls.dropFirst(index)),
                        to: remoteDirectory,
                        profile: profile,
                        password: password
                    )
                case .failure(let error):
                    return .failure(partialOperationError(error, names: urls.map(\.lastPathComponent), failedIndex: index))
                }
            }

            return .success(())
        }

        return uploadItemsWithSFTP(urls, to: remoteDirectory, profile: profile, password: password)
    }

    private nonisolated static func uploadItemsWithSFTP(_ urls: [URL], to remoteDirectory: String, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        performItems(urls, names: urls.map(\.lastPathComponent)) { url in
            let remoteTarget = joined(remoteDirectory, url.lastPathComponent)
            let option = isDirectory(url) ? "-R " : ""
            let command = "put \(option)\(sftpQuoted(url.path)) \(sftpQuoted(remoteTarget))"
            return runSFTPCommands(command, profile: profile, password: password, fallbackMessage: "SFTP upload failed")
        }
    }

    private nonisolated static func remoteTransferUnitCount(for item: RemoteFileItem, profile: ServerProfile, password: String?) -> Int {
        guard item.isDirectory else {
            return 1
        }

        switch remoteTransferUnitCount(forDirectory: item.path, profile: profile, password: password) {
        case .success(let count):
            return max(count, 1)
        case .failure:
            return 1
        }
    }

    private nonisolated static func remoteTransferUnitCount(forDirectory path: String, profile: ServerProfile, password: String?) -> Result<Int, RemoteFileError> {
        switch loadDirectory(profile: profile, path: path, password: password) {
        case .success(let items):
            var count = 0
            for item in items {
                if item.isDirectory {
                    switch remoteTransferUnitCount(forDirectory: item.path, profile: profile, password: password) {
                    case .success(let childCount):
                        count += childCount
                    case .failure(let error):
                        return .failure(error)
                    }
                } else {
                    count += 1
                }
            }
            return .success(count)
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static var isRsyncAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync")
    }

    private nonisolated static func uploadItemWithRsync(
        _ url: URL,
        to remoteDirectory: String,
        profile: ServerProfile,
        password: String?,
        itemIndex: Int? = nil,
        itemCount: Int? = nil,
        itemOffset: Int? = nil,
        transferUnitCount: Int? = nil,
        progress: (@Sendable (RemoteTransferProgress) -> Void)?
    ) -> Result<Void, RemoteFileError> {
        runRsyncTransfer(
            sources: [url.path],
            destination: rsyncRemoteSpec(profile: profile, path: directoryPathForRsync(remoteDirectory)),
            itemName: url.lastPathComponent,
            itemIndex: itemIndex,
            itemCount: itemCount,
            itemOffset: itemOffset,
            transferUnitCount: transferUnitCount,
            profile: profile,
            password: password,
            fallbackMessage: "Rsync upload failed",
            progress: progress
        )
    }

    private nonisolated static func downloadItemWithRsync(
        _ item: RemoteFileItem,
        to destination: URL,
        profile: ServerProfile,
        password: String?,
        itemIndex: Int? = nil,
        itemCount: Int? = nil,
        itemOffset: Int? = nil,
        transferUnitCount: Int? = nil,
        progress: (@Sendable (RemoteTransferProgress) -> Void)?
    ) -> Result<Void, RemoteFileError> {
        if item.isDirectory {
            let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                return .failure(RemoteFileError(message: error.localizedDescription))
            }

            let result = runRsyncTransfer(
                sources: [rsyncRemoteSpec(profile: profile, path: directoryPathForRsync(item.path))],
                destination: directoryPathForRsync(destination.path),
                itemName: item.name,
                itemIndex: itemIndex,
                itemCount: itemCount,
                itemOffset: itemOffset,
                transferUnitCount: transferUnitCount,
                profile: profile,
                password: password,
                fallbackMessage: "Rsync download failed",
                progress: progress
            )

            if !destinationExisted,
               case .failure(let error) = result,
               shouldFallbackFromRsync(error) {
                tryRemoveEmptyDirectory(at: destination)
            }
            return result
        }

        return runRsyncTransfer(
            sources: [rsyncRemoteSpec(profile: profile, path: item.path)],
            destination: destination.path,
            itemName: item.name,
            itemIndex: itemIndex,
            itemCount: itemCount,
            itemOffset: itemOffset,
            transferUnitCount: transferUnitCount,
            profile: profile,
            password: password,
            fallbackMessage: "Rsync download failed",
            progress: progress
        )
    }

    private nonisolated static func downloadItemToDirectoryWithRsync(
        _ item: RemoteFileItem,
        toDirectory destination: URL,
        profile: ServerProfile,
        password: String?,
        itemIndex: Int? = nil,
        itemCount: Int? = nil,
        itemOffset: Int? = nil,
        transferUnitCount: Int? = nil,
        progress: (@Sendable (RemoteTransferProgress) -> Void)?
    ) -> Result<Void, RemoteFileError> {
        runRsyncTransfer(
            sources: [rsyncRemoteSpec(profile: profile, path: item.path)],
            destination: directoryPathForRsync(destination.path),
            itemName: item.name,
            itemIndex: itemIndex,
            itemCount: itemCount,
            itemOffset: itemOffset,
            transferUnitCount: transferUnitCount,
            profile: profile,
            password: password,
            fallbackMessage: "Rsync download failed",
            progress: progress
        )
    }

    private nonisolated static func runRsyncTransfer(
        sources: [String],
        destination: String,
        itemName: String,
        itemIndex: Int?,
        itemCount: Int?,
        itemOffset: Int? = nil,
        transferUnitCount: Int? = nil,
        profile: ServerProfile,
        password: String?,
        fallbackMessage: String,
        progress: (@Sendable (RemoteTransferProgress) -> Void)?
    ) -> Result<Void, RemoteFileError> {
        let parser = RsyncProgressParser()
        var arguments = [
            "-a",
            "--partial",
            "--progress",
            "--timeout=60",
            "-e",
            SSHCommandBuilder.rsyncRemoteShell(for: profile, allowPassword: password != nil)
        ]
        arguments.append(contentsOf: sources)
        arguments.append(destination)

        let askPassSession = SSHAskPassSession(password: password)
        defer {
            askPassSession?.stop()
        }

        let result = runProcess(
            executablePath: "/usr/bin/rsync",
            arguments: arguments,
            environment: remoteProcessEnvironment(askPassSession: askPassSession),
            input: nil,
            timeoutMessage: localizedFormat("%@: timed out", fallbackMessage),
            overallTimeout: nil
        ) { text in
            guard let event = parser.append(text) else {
                return
            }

            let resolvedItemIndex = event.itemIndex.map { (itemOffset ?? 0) + $0 } ?? itemIndex
            let resolvedItemCount = event.itemIndex == nil ? itemCount : (transferUnitCount ?? itemCount)

            progress?(
                RemoteTransferProgress(
                    itemName: event.itemName ?? itemName,
                    itemIndex: resolvedItemIndex,
                    itemCount: resolvedItemCount,
                    percent: event.percent
                )
            )
        }

        switch result {
        case .success(let subprocessResult):
            guard subprocessResult.terminationStatus == 0 else {
                let message = [subprocessResult.errorText, subprocessResult.outputText]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(RemoteFileError(message: message.isEmpty ? fallbackMessage : message))
            }
            if transferUnitCount == nil {
                progress?(
                    RemoteTransferProgress(
                        itemName: itemName,
                        itemIndex: itemIndex,
                        itemCount: itemCount,
                        percent: 100
                    )
                )
            }
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func shouldFallbackFromRsync(_ error: RemoteFileError) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("rsync: command not found")
            || message.contains("rsync: not found")
            || message.contains("rsync not found")
            || (message.contains("rsync") && message.contains("no such file or directory"))
            || message.contains("protocol version mismatch")
            || message.contains("incompatible rsync")
    }

    private nonisolated static func rsyncRemoteSpec(profile: ServerProfile, path: String) -> String {
        "\(profile.destination):\(SSHCommandBuilder.shellQuotedArgument(path))"
    }

    private nonisolated static func directoryPathForRsync(_ path: String) -> String {
        if path.isEmpty {
            return "./"
        }
        return path.hasSuffix("/") ? path : "\(path)/"
    }

    private nonisolated static func tryRemoveEmptyDirectory(at url: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              contents.isEmpty else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func copyItems(_ items: [RemoteFileItem], to remoteDirectory: String, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        let requests: [FilePermissionPreflight.Request] = items.map { .init(path: $0.path, access: .read) }
            + [.init(path: remoteDirectory, access: .directory)]
            + items.map { .init(path: joined(remoteDirectory, $0.name), access: .write) }
        if case .failure(let error) = checkRemotePermissions(requests, profile: profile, password: password) { return .failure(error) }
        return performItems(items, names: items.map(\.name)) { item in
            let command = "cp -R -- \(shellQuoted(item.path)) \(shellQuoted(remoteDirectory))"
            return runRemoteCommand(command, profile: profile, password: password, fallbackMessage: "Remote copy failed")
        }
    }

    private nonisolated static func copyItemsBetweenServers(
        _ items: [RemoteFileItem],
        from sourceProfile: ServerProfile,
        sourcePassword: String?,
        to remoteDirectory: String,
        targetProfile: ServerProfile,
        targetPassword: String?,
        progress: (@Sendable (RemoteTransferProgress) -> Void)? = nil
    ) -> Result<Void, RemoteFileError> {
        if sourceProfile.id == targetProfile.id {
            return copyItems(items, to: remoteDirectory, profile: sourceProfile, password: sourcePassword)
        }

        return copyItemsThroughTemporaryDirectory(
            items,
            from: sourceProfile,
            sourcePassword: sourcePassword,
            to: remoteDirectory,
            targetProfile: targetProfile,
            targetPassword: targetPassword,
            progress: progress
        )
    }

    private nonisolated static func copyItemsThroughTemporaryDirectory(
        _ items: [RemoteFileItem],
        from sourceProfile: ServerProfile,
        sourcePassword: String?,
        to remoteDirectory: String,
        targetProfile: ServerProfile,
        targetPassword: String?,
        progress: (@Sendable (RemoteTransferProgress) -> Void)? = nil
    ) -> Result<Void, RemoteFileError> {
        let requests: [FilePermissionPreflight.Request] = [.init(path: remoteDirectory, access: .directory)] + items.map { .init(path: joined(remoteDirectory, $0.name), access: .write) }
        if case .failure(let error) = checkRemotePermissions(requests, profile: targetProfile, password: targetPassword) { return .failure(error) }
        if case .failure(let error) = checkRemotePermissions(items.map { .init(path: $0.path, access: .read) }, profile: sourceProfile, password: sourcePassword) { return .failure(error) }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrnithopterServerTransfers", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(RemoteFileError(message: error.localizedDescription))
        }

        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        switch downloadItems(items, toDirectory: temporaryDirectory, profile: sourceProfile, password: sourcePassword, progress: progress) {
        case .success:
            let localURLs = items.map { item in
                temporaryDirectory.appendingPathComponent(item.name, isDirectory: item.isDirectory)
            }
            return uploadItems(localURLs, to: remoteDirectory, profile: targetProfile, password: targetPassword, progress: progress)
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func makeDirectory(_ path: String, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        runSFTPCommands("mkdir \(sftpQuoted(path))", profile: profile, password: password, fallbackMessage: "SFTP mkdir failed")
    }

    private nonisolated static func validateUploadSources(_ urls: [URL], existingItems: [RemoteFileItem] = []) -> NameValidation {
        var names = Set<String>()
        let existingNames = Set(existingItems.map(\.name))

        for url in urls {
            let validation = validateRemoteName(url.lastPathComponent)
            guard validation.isValid, let name = validation.name else {
                return NameValidation(name: validation.name, message: validation.message)
            }

            guard !names.contains(name) else {
                return NameValidation(name: name, message: localizedFormat("Multiple selected items are named %@.", name))
            }

            guard !existingNames.contains(name) else {
                return NameValidation(name: name, message: localizedFormat("An item named %@ already exists.", name))
            }

            names.insert(name)
        }

        return NameValidation(name: nil, message: nil)
    }

    private nonisolated static func validateRemoteName(_ proposedName: String) -> NameValidation {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            return NameValidation(name: nil, message: localized("Name cannot be empty."))
        }

        guard name != "." && name != ".." else {
            return NameValidation(name: name, message: localizedFormat("%@ is not allowed.", name))
        }

        guard !name.contains("/") && !name.contains("\0") else {
            return NameValidation(name: name, message: localized("Name cannot contain / or null characters."))
        }

        return NameValidation(name: name, message: nil)
    }

    private nonisolated static func firstDuplicateName(_ names: [String]) -> String? {
        var seen = Set<String>()
        for name in names {
            guard !seen.contains(name) else {
                return name
            }

            seen.insert(name)
        }
        return nil
    }

    private nonisolated static func renameItem(_ item: RemoteFileItem, to newPath: String, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        runSFTPCommands(
            "rename \(sftpQuoted(item.path)) \(sftpQuoted(newPath))",
            profile: profile,
            password: password,
            fallbackMessage: "SFTP rename failed"
        )
    }

    private nonisolated static func renameItems(_ items: [RemoteFileItem], to remoteDirectory: String, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        let requests: [FilePermissionPreflight.Request] = items.map { .init(path: $0.path, access: .move) } + [.init(path: remoteDirectory, access: .directory)]
        if case .failure(let error) = checkRemotePermissions(requests, profile: profile, password: password) { return .failure(error) }
        return performItems(items, names: items.map(\.name)) { item in
            let newPath = joined(remoteDirectory, item.name)
            return runSFTPCommands("rename \(sftpQuoted(item.path)) \(sftpQuoted(newPath))", profile: profile, password: password, fallbackMessage: "SFTP move failed")
        }
    }

    private nonisolated static func deleteItem(_ item: RemoteFileItem, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        if !item.isDirectory {
            return runSFTPCommands("rm \(sftpQuoted(item.path))", profile: profile, password: password, fallbackMessage: "SFTP delete failed")
        }

        switch recursiveDeleteCommands(for: item.path, profile: profile, password: password) {
        case .success(let commands):
            return runSFTPCommands(commands.joined(separator: "\n"), profile: profile, password: password, fallbackMessage: "SFTP delete failed")
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func deleteItems(_ items: [RemoteFileItem], profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        if case .failure(let error) = checkRemotePermissions(items.map { .init(path: $0.path, access: .delete) }, profile: profile, password: password) {
            return .failure(error)
        }
        return performItems(items, names: items.map(\.name)) { item in
            deleteItem(item, profile: profile, password: password)
        }
    }

    private nonisolated static func performItems<Item>(_ items: [Item], names: [String], operation: (Item) -> Result<Void, RemoteFileError>) -> Result<Void, RemoteFileError> {
        for (index, item) in items.enumerated() {
            if case .failure(let error) = operation(item) {
                return .failure(partialOperationError(error, names: names, failedIndex: index))
            }
        }
        return .success(())
    }

    private nonisolated static func checkDownloadDestinations(_ items: [RemoteFileItem], destinations: [URL], profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        var issues = FilePermissionPreflight.localWriteIssues(destinations)
        var pending = Array(zip(items, destinations))
        while let (item, destination) = pending.popLast() {
            guard item.isDirectory, FileManager.default.fileExists(atPath: destination.path) else { continue }
            switch loadDirectory(profile: profile, path: item.path, password: password) {
            case .failure(let error): return .failure(error)
            case .success(let children):
                let targets = children.map { destination.appendingPathComponent($0.name) }
                issues.append(contentsOf: FilePermissionPreflight.localWriteIssues(targets))
                pending.append(contentsOf: zip(children, targets))
            }
        }
        return issues.isEmpty ? .success(()) : .failure(RemoteFileError(message: FilePermissionPreflight.message(issues)))
    }

    private nonisolated static func partialOperationError(_ error: RemoteFileError, names: [String], failedIndex: Int) -> RemoteFileError {
        let completed = names.prefix(failedIndex).joined(separator: ", ")
        let pending = names.dropFirst(failedIndex + 1).joined(separator: ", ")
        return RemoteFileError(message: error.localizedDescription + "\n\n"
            + localizedFormat("Failed (may be partially completed): %@", names[failedIndex])
            + (completed.isEmpty ? "" : "\n" + localizedFormat("Completed: %@", completed))
            + (pending.isEmpty ? "" : "\n" + localizedFormat("Not started: %@", pending)))
    }

    private nonisolated static func checkRemotePermissions(_ requests: [FilePermissionPreflight.Request], profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        guard !requests.isEmpty else { return .success(()) }
        let askPass = SSHAskPassSession(password: password)
        defer { askPass?.stop() }
        let result = runProcess(
            executablePath: "/usr/bin/ssh",
            arguments: SSHCommandBuilder.remoteCommandArguments(for: profile, command: "sh -s", allowPassword: password != nil),
            environment: remoteProcessEnvironment(askPassSession: askPass),
            input: FilePermissionPreflight.remoteCommand(requests),
            timeoutMessage: localized("Permission check timed out"),
            overallTimeout: 60
        )
        let outcome: FilePermissionPreflight.Outcome
        let detail: String
        switch result {
        case .success(let output):
            if output.terminationStatus == 255 {
                return .failure(RemoteFileError(message: output.errorText.isEmpty ? localized("Permission check connection failed") : output.errorText))
            }
            outcome = FilePermissionPreflight.parseRemoteOutput(output.outputText, status: output.terminationStatus)
            detail = output.errorText
        case .failure(let error):
            return .failure(error)
        }
        switch outcome {
        case .allowed: return .success(())
        case .denied(let issues): return .failure(RemoteFileError(message: FilePermissionPreflight.message(issues)))
        case .unavailable:
            // All file work runs off the main thread. Wait only for the explicit
            // decision when a restricted server cannot perform read-only checks.
            let proceed = DispatchQueue.main.sync {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = localized("Unable to Verify Permissions")
                alert.informativeText = profile.displayName + "\n" + localized("The server could not verify access. Attempt the operation anyway?") + "\n\n" + String(detail.prefix(1200))
                alert.addButton(withTitle: localized("Cancel"))
                alert.addButton(withTitle: localized("Attempt Operation"))
                return alert.runModal() == .alertSecondButtonReturn
            }
            return proceed ? .success(()) : .failure(RemoteFileError(message: localized("Permission check cancelled. No files were changed.")))
        }
    }

    private nonisolated static func recursiveDeleteCommands(for directory: String, profile: ServerProfile, password: String?) -> Result<[String], RemoteFileError> {
        switch loadDirectory(profile: profile, path: directory, password: password) {
        case .success(let items):
            var commands: [String] = []

            for item in items {
                if item.isDirectory {
                    switch recursiveDeleteCommands(for: item.path, profile: profile, password: password) {
                    case .success(let childCommands):
                        commands.append(contentsOf: childCommands)
                    case .failure(let error):
                        return .failure(error)
                    }
                } else {
                    commands.append("rm \(sftpQuoted(item.path))")
                }
            }

            commands.append("rmdir \(sftpQuoted(directory))")
            return .success(commands)
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func runSFTPCommands(_ commands: String, profile: ServerProfile, password: String?, fallbackMessage: String) -> Result<Void, RemoteFileError> {
        let result = runSFTPProcess(
            input: commands + "\nquit\n",
            profile: profile,
            password: password,
            timeoutMessage: localizedFormat("%@: timed out", fallbackMessage)
        )

        switch result {
        case .success(let subprocessResult):
            guard subprocessResult.terminationStatus == 0 else {
                let message = [subprocessResult.errorText, subprocessResult.outputText]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(RemoteFileError(message: message.isEmpty ? fallbackMessage : message))
            }
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func runRemoteCommand(_ command: String, profile: ServerProfile, password: String?, fallbackMessage: String) -> Result<Void, RemoteFileError> {
        runRemoteCommandWithOutput(command, profile: profile, password: password, fallbackMessage: fallbackMessage)
    }

    private nonisolated static func runRemoteCommandWithOutput(
        _ command: String,
        profile: ServerProfile,
        password: String?,
        fallbackMessage: String,
        overallTimeout: TimeInterval? = 20,
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) -> Result<Void, RemoteFileError> {
        let askPassSession = SSHAskPassSession(password: password)
        defer {
            askPassSession?.stop()
        }

        let result = runProcess(
            executablePath: "/usr/bin/ssh",
            arguments: SSHCommandBuilder.remoteCommandArguments(for: profile, command: command, allowPassword: password != nil),
            environment: remoteProcessEnvironment(askPassSession: askPassSession),
            input: nil,
            timeoutMessage: localizedFormat("%@: timed out", fallbackMessage),
            overallTimeout: overallTimeout,
            outputHandler: outputHandler
        )

        switch result {
        case .success(let subprocessResult):
            guard subprocessResult.terminationStatus == 0 else {
                let message = [subprocessResult.errorText, subprocessResult.outputText]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(RemoteFileError(message: message.isEmpty ? fallbackMessage : message))
            }
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func runSFTPProcess(input: String, profile: ServerProfile, password: String?, timeoutMessage: String) -> Result<RemoteSubprocessResult, RemoteFileError> {
        let askPassSession = SSHAskPassSession(password: password)
        defer {
            askPassSession?.stop()
        }

        return runProcess(
            executablePath: "/usr/bin/sftp",
            arguments: SSHCommandBuilder.sftpArguments(for: profile, allowPassword: password != nil),
            environment: remoteProcessEnvironment(askPassSession: askPassSession),
            input: input,
            timeoutMessage: timeoutMessage
        )
    }

    private nonisolated static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        input: String?,
        timeoutMessage: String,
        overallTimeout: TimeInterval? = 20,
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) -> Result<RemoteSubprocessResult, RemoteFileError> {
        let process = Process()
        let inputPipe = input.map { _ in Pipe() }
        let output = Pipe()
        let errorPipe = Pipe()
        let outputCollector = ProcessOutputCollector(outputHandler: outputHandler)
        let errorCollector = ProcessOutputCollector(outputHandler: outputHandler)

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = output
        process.standardError = errorPipe

        defer {
            outputCollector.stop(readingFrom: output.fileHandleForReading)
            errorCollector.stop(readingFrom: errorPipe.fileHandleForReading)
            try? inputPipe?.fileHandleForWriting.close()
        }

        do {
            try process.run()
            try? inputPipe?.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            try outputCollector.start(readingFrom: output.fileHandleForReading)
            try errorCollector.start(readingFrom: errorPipe.fileHandleForReading)

            if let input, let inputPipe {
                try ProcessPipeWriter.write(Data(input.utf8), to: inputPipe.fileHandleForWriting.fileDescriptor, timeout: overallTimeout ?? 20)
                try? inputPipe.fileHandleForWriting.close()
            }

            guard waitForProcess(process, timeout: overallTimeout) else {
                processLogger.error("File subprocess timed out: \(executablePath, privacy: .public)")
                outputCollector.stop(readingFrom: output.fileHandleForReading)
                errorCollector.stop(readingFrom: errorPipe.fileHandleForReading)
                return .failure(RemoteFileError(message: timeoutMessage))
            }

            processLogger.info("File subprocess \(executablePath, privacy: .public) exited: \(process.terminationStatus)")

            return .success(
                RemoteSubprocessResult(
                    outputText: try outputCollector.finish(readingFrom: output.fileHandleForReading),
                    errorText: try errorCollector.finish(readingFrom: errorPipe.fileHandleForReading),
                    terminationStatus: process.terminationStatus
                )
            )
        } catch {
            processLogger.error("File subprocess failed: \(executablePath, privacy: .public), error \((error as NSError).code)")
            if process.isRunning { _ = waitForProcess(process, timeout: 0) }
            outputCollector.stop(readingFrom: output.fileHandleForReading)
            errorCollector.stop(readingFrom: errorPipe.fileHandleForReading)
            try? inputPipe?.fileHandleForWriting.close()
            return .failure(RemoteFileError(message: error.localizedDescription))
        }
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private nonisolated static func transferUnitCount(for url: URL) -> Int {
        guard isDirectory(url) else {
            return 1
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return 1
        }

        var count = 0
        for case let childURL as URL in enumerator {
            if (try? childURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }

        return max(count, 1)
    }

    private nonisolated static func dragSuggestedName(for item: RemoteFileItem) -> String {
        guard !item.isDirectory else {
            return item.name
        }

        let nsName = item.name as NSString
        guard !nsName.pathExtension.isEmpty else {
            return item.name
        }

        let baseName = nsName.deletingPathExtension
        return baseName.isEmpty ? item.name : baseName
    }

    private nonisolated static func dragSuggestedName(for items: [RemoteFileItem], draggedItem: RemoteFileItem) -> String {
        guard items.count > 1 else {
            return dragSuggestedName(for: draggedItem)
        }

        return "Ornithopter Selection"
    }

    private nonisolated static func dragTypeIdentifier(for items: [RemoteFileItem], draggedItem: RemoteFileItem) -> String {
        if items.count > 1 || draggedItem.isDirectory {
            return UTType.folder.identifier
        }

        return UTType(filenameExtension: (draggedItem.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier
    }

    private nonisolated static func temporaryDragDestination(for items: [RemoteFileItem], draggedItem: RemoteFileItem) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrnithopterDragDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        guard items.count > 1 else {
            return folder.appendingPathComponent(draggedItem.name, isDirectory: draggedItem.isDirectory)
        }

        return folder.appendingPathComponent("Ornithopter Selection", isDirectory: true)
    }

    private nonisolated static func remoteProcessEnvironment(askPassSession: SSHAskPassSession?) -> [String: String] {
        SSHProcessEnvironment.baseEnvironment()
            .merging(askPassSession?.environment ?? [:]) { _, new in new }
    }

    private nonisolated static func waitForProcess(_ process: Process, timeout: TimeInterval?) -> Bool {
        guard process.isRunning else {
            return true
        }

        guard let timeout else {
            process.waitUntilExit()
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        guard process.isRunning else {
            return true
        }

        if semaphore.wait(timeout: .now() + timeout) == .success {
            return true
        }

        process.terminate()
        if semaphore.wait(timeout: .now() + 2) == .success {
            return false
        }

        kill(process.processIdentifier, SIGKILL)
        _ = semaphore.wait(timeout: .now() + 2)
        return false
    }

    private nonisolated static func joined(_ base: String, _ child: String) -> String {
        if base == "/" {
            return "/\(child)"
        }
        if base == "." || base.isEmpty {
            return child
        }
        return "\(base)/\(child)"
    }

    private nonisolated static func parentPath(_ path: String) -> String {
        guard path != "." && path != "/" else {
            return path
        }

        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else {
            return path.hasPrefix("/") ? "/" : "."
        }

        if path.hasPrefix("/") {
            return "/" + parts.dropLast().joined(separator: "/")
        }

        return parts.dropLast().joined(separator: "/")
    }

    private nonisolated static func normalizedRemoteBrowserPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" {
            return "."
        }
        if trimmed.hasPrefix("~/") {
            let relativePath = String(trimmed.dropFirst(2))
            return relativePath.isEmpty ? "." : relativePath
        }
        return trimmed
    }

    private nonisolated static func sftpListCommands(for path: String) -> String {
        let lsCommand = "ls -an"

        if path == "." || path == "~" || path.isEmpty {
            return """
            \(lsCommand)
            quit
            """
        }

        return """
        cd \(sftpQuoted(path))
        \(lsCommand)
        quit
        """
    }

    private nonisolated static func sftpQuoted(_ value: String) -> String {
        if value == "~" || value.hasPrefix("~/") {
            return value.replacingOccurrences(of: " ", with: "\\ ")
        }

        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func askDownloadDestination(for item: RemoteFileItem) -> URL? {
        let panel = NSSavePanel()
        panel.title = Self.localizedFormat("Download %@", item.name)
        panel.prompt = Self.localized("Download")
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = item.isDirectory
            ? Self.localized("Choose where to save this remote folder.")
            : Self.localized("Choose where to save this remote file.")

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    private func askDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = Self.localized("Download Selected Items")
        panel.prompt = Self.localized("Download")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = Self.localized("Choose a local folder for the selected remote items.")

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    private func askUploadSources() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = Self.localized("Upload Files")
        panel.prompt = Self.localized("Upload")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.message = Self.localized("Choose local files or folders to upload.")

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.urls
    }

    private func askRemoteDirectory(profile targetProfile: ServerProfile, password: String?) -> String? {
        var path = Self.normalizedRemoteBrowserPath(targetProfile.remotePath)
        var state = remoteFolderChooserState(profile: targetProfile, path: path, password: password)
        let chooser = makeRemoteFolderChooser(
            profileName: targetProfile.displayName,
            path: path,
            message: state.message,
            folders: state.folders
        )

        while true {
            chooser.controller.action = .cancel
            NSApp.runModal(for: chooser.panel)

            switch chooser.controller.action {
            case .choose:
                return path
            case .open:
                if let selectedPath = chooser.controller.selectedFolderPath {
                    path = Self.normalizedRemoteBrowserPath(selectedPath)
                    state = remoteFolderChooserState(profile: targetProfile, path: path, password: password)
                    chooser.controller.update(path: path, message: state.message, folders: state.folders)
                }
            case .up:
                path = Self.parentPath(path)
                state = remoteFolderChooserState(profile: targetProfile, path: path, password: password)
                chooser.controller.update(path: path, message: state.message, folders: state.folders)
            case .refresh:
                state = remoteFolderChooserState(profile: targetProfile, path: path, password: password)
                chooser.controller.update(path: path, message: state.message, folders: state.folders)
            case .newFolder:
                guard let folderName = askRemoteNewFolderName(in: path, existingItems: state.items) else {
                    continue
                }

                let newPath = Self.joined(path, folderName)
                switch Self.makeDirectory(newPath, profile: targetProfile, password: password) {
                case .success:
                    path = newPath
                    state = remoteFolderChooserState(profile: targetProfile, path: path, password: password)
                    chooser.controller.update(path: path, message: state.message, folders: state.folders)
                case .failure(let error):
                    status = "\(folderName): \(error.localizedDescription)"
                    chooser.controller.update(path: path, message: status, folders: state.folders)
                }
            case .cancel:
                return nil
            }
        }
    }

    private func remoteFolderChooserState(
        profile targetProfile: ServerProfile,
        path: String,
        password: String?
    ) -> (items: [RemoteFileItem], folders: [RemoteFileItem], message: String) {
        let itemsResult = Self.loadDirectory(profile: targetProfile, path: path, password: password)
        switch itemsResult {
        case .success(let loadedItems):
            self.status = Self.localizedFormat("%@: %d items", path, visibleItems(loadedItems).count)
            return (
                items: loadedItems,
                folders: loadedItems.filter(\.isDirectory),
                message: Self.localizedFormat("Choose a destination folder on %@.", targetProfile.displayName)
            )
        case .failure(let error):
            return (items: [], folders: [], message: "\(path): \(error.localizedDescription)")
        }
    }

    private func makeRemoteFolderChooser(
        profileName: String,
        path: String,
        message: String,
        folders: [RemoteFileItem]
    ) -> (panel: NSPanel, controller: RemoteFolderChooserController) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = Self.localized("Choose Remote Folder")
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let controller = RemoteFolderChooserController(folders: folders)
        controller.panel = panel
        panel.delegate = controller

        let content = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 560, height: 420))
        content.autoresizingMask = [.width, .height]
        panel.contentView = content

        let titleLabel = NSTextField(labelWithString: profileName)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: 380, width: 520, height: 18)
        titleLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(titleLabel)

        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.frame = NSRect(x: 20, y: 356, width: 520, height: 18)
        messageLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(messageLabel)
        controller.messageLabel = messageLabel

        let pathField = NSTextField(labelWithString: path)
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.backgroundColor = .controlBackgroundColor
        pathField.drawsBackground = true
        pathField.isBezeled = true
        pathField.frame = NSRect(x: 20, y: 324, width: 520, height: 24)
        pathField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(pathField)
        controller.pathField = pathField

        let upButton = NSButton(title: Self.localized("Up"), target: controller, action: #selector(RemoteFolderChooserController.goUp))
        upButton.frame = NSRect(x: 20, y: 290, width: 72, height: 28)
        upButton.bezelStyle = .rounded
        content.addSubview(upButton)

        let refreshButton = NSButton(title: Self.localized("Refresh"), target: controller, action: #selector(RemoteFolderChooserController.refresh))
        refreshButton.frame = NSRect(x: 100, y: 290, width: 88, height: 28)
        refreshButton.bezelStyle = .rounded
        content.addSubview(refreshButton)

        let newFolderButton = NSButton(title: Self.localized("New Folder..."), target: controller, action: #selector(RemoteFolderChooserController.newFolder))
        newFolderButton.frame = NSRect(x: 196, y: 290, width: 116, height: 28)
        newFolderButton.bezelStyle = .rounded
        content.addSubview(newFolderButton)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 70, width: 520, height: 214))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Folder"))
        column.title = Self.localized("Folder")
        column.resizingMask = .autoresizingMask
        controller.tableView.addTableColumn(column)
        controller.tableView.headerView = nil
        controller.tableView.rowHeight = 24
        controller.tableView.usesAlternatingRowBackgroundColors = true
        controller.tableView.delegate = controller
        controller.tableView.dataSource = controller
        controller.tableView.target = controller
        controller.tableView.doubleAction = #selector(RemoteFolderChooserController.doubleClickRow)
        scrollView.documentView = controller.tableView
        content.addSubview(scrollView)

        let emptyLabel = NSTextField(labelWithString: Self.localized("No folders"))
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 20, y: 164, width: 520, height: 20)
        emptyLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        emptyLabel.isHidden = !folders.isEmpty
        content.addSubview(emptyLabel)
        controller.emptyLabel = emptyLabel

        let cancelButton = NSButton(title: Self.localized("Cancel"), target: controller, action: #selector(RemoteFolderChooserController.cancel))
        cancelButton.frame = NSRect(x: 340, y: 24, width: 88, height: 30)
        cancelButton.bezelStyle = .rounded
        cancelButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(cancelButton)

        let chooseButton = NSButton(title: Self.localized("Choose This Folder"), target: controller, action: #selector(RemoteFolderChooserController.chooseFolder))
        chooseButton.frame = NSRect(x: 436, y: 24, width: 104, height: 30)
        chooseButton.bezelStyle = .rounded
        chooseButton.keyEquivalent = "\r"
        chooseButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(chooseButton)

        return (panel, controller)
    }

    private func askRemoteNewFolderName(in path: String, existingItems: [RemoteFileItem]) -> String? {
        let alert = NSAlert()
        alert.messageText = Self.localized("New Folder...")
        alert.informativeText = path
        alert.addButton(withTitle: Self.localized("OK"))
        alert.addButton(withTitle: Self.localized("Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = NSLocalizedString("Untitled Folder", comment: "Default name for a new remote folder")
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let validation = Self.validateRemoteName(field.stringValue)
        guard validation.isValid, let name = validation.name else {
            status = validation.message ?? Self.localized("Invalid folder name")
            return nil
        }

        guard !existingItems.contains(where: { $0.name == name }) else {
            status = Self.localizedFormat("An item named %@ already exists.", name)
            return nil
        }

        return name
    }

    private func confirmDelete(_ item: RemoteFileItem) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("Delete %@?", comment: "Delete remote item confirmation title"), item.name)
        alert.informativeText = item.isDirectory
            ? NSLocalizedString("This will delete the remote folder and its contents.", comment: "Delete remote folder message")
            : NSLocalizedString("This will delete the remote file.", comment: "Delete remote file message")
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Delete confirmation button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDelete(_ items: [RemoteFileItem]) -> Bool {
        guard items.count != 1 else {
            return confirmDelete(items[0])
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString("Delete %d items?", comment: "Delete multiple remote items confirmation title"),
            items.count
        )
        alert.informativeText = NSLocalizedString("This will delete the selected remote files and folders.", comment: "Delete multiple remote items message")
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Delete confirmation button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

        return alert.runModal() == .alertFirstButtonReturn
    }

    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let url = item as? NSURL {
            return url as URL
        }

        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }

        if let string = item as? String {
            return URL(string: string)
        }

        return nil
    }
}

struct RemoteFolderBrowser: View {
    @StateObject private var store: RemoteFileStore
    @AppStorage("supportedTextFilePatterns") private var supportedTextFilePatterns = AppPreferenceDefaults.supportedTextFilePatterns
    let availableProfiles: [ServerProfile]
    let collapseAction: () -> Void
    let editAction: (RemoteFileItem) -> Void

    init(
        profile: ServerProfile,
        availableProfiles: [ServerProfile] = [],
        sessionPassword: String? = nil,
        collapseAction: @escaping () -> Void,
        editAction: @escaping (RemoteFileItem) -> Void = { _ in }
    ) {
        _store = StateObject(wrappedValue: RemoteFileStore(profile: profile, sessionPassword: sessionPassword))
        self.availableProfiles = availableProfiles
        self.collapseAction = collapseAction
        self.editAction = editAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Files")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")

                Button(action: collapseAction) {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(.borderless)
                .help("Hide Files")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            RemoteFileOutlineView(store: store, availableProfiles: availableProfiles,
                                  supportedTextFilePatterns: supportedTextFilePatterns, editAction: editAction)

            VStack(alignment: .leading, spacing: 5) {
                Text(store.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                if let transferPercent = store.transferPercent {
                    ProgressView(value: transferPercent)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            .padding(10)
        }
        .frame(minWidth: 180)
        .task {
            store.refresh()
            await store.refreshAfterDelay(seconds: 3)
            await store.refreshAfterDelay(seconds: 7)
        }
    }
}
