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

struct RemoteFileItem: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool

    var id: String {
        path
    }

    var isHidden: Bool {
        name.hasPrefix(".")
    }
}

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

private struct RemoteDragContext {
    let profile: ServerProfile
    let sessionPassword: String?
    let items: [RemoteFileItem]
}

@MainActor
final class RemoteFileStore: ObservableObject {
    @Published private(set) var currentPath: String
    @Published private(set) var items: [RemoteFileItem] = []
    @Published private(set) var childrenByPath: [String: [RemoteFileItem]] = [:]
    @Published private(set) var expandedPaths: Set<String> = []
    @Published private(set) var loadingPaths: Set<String> = []
    @Published private(set) var downloadingPaths: Set<String> = []
    @Published private(set) var uploadingPaths: Set<String> = []
    @Published private(set) var movingPaths: Set<String> = []
    @Published private(set) var selectedPaths: Set<String> = []
    @Published private(set) var copiedItems: [RemoteFileItem] = []
    @Published private(set) var newFolderParent: String?
    @Published private(set) var status = "Not loaded"

    static let acceptedDropTypes: [UTType] = [.item, .fileURL]
    private static var sharedDragContext: RemoteDragContext?

    private let profile: ServerProfile
    private let sessionPassword: String?
    private var draggedRemoteItems: [RemoteFileItem] = []

    init(profile: ServerProfile, sessionPassword: String?) {
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
        for path in expandedPaths.sorted() {
            childrenByPath.removeValue(forKey: path)
            loadChildren(path: path)
        }
    }

    private func load(path: String, updateCurrentPath: Bool, resetTree: Bool) {
        status = "Loading..."
        if resetTree {
            expandedPaths.removeAll()
            childrenByPath.removeAll()
        }

        Task.detached { [profile, sessionPassword] in
            let result = Self.loadDirectory(profile: profile, path: path, password: sessionPassword)

            await MainActor.run {
                switch result {
                case .success(let items):
                    if updateCurrentPath {
                        self.currentPath = path
                    }
                    self.items = items
                    self.childrenByPath[path] = items
                    let visibleCount = self.visibleItems(items).count
                    self.status = visibleCount == 0 ? "Empty folder" : "\(visibleCount) items"
                case .failure(let error):
                    if !updateCurrentPath {
                        self.items = []
                    }
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
        guard item.isDirectory else {
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

    func isCreatingFolder(in path: String) -> Bool {
        newFolderParent == path
    }

    func uploadTarget(for item: RemoteFileItem) -> String {
        item.isDirectory ? item.path : Self.parentPath(item.path)
    }

    func select(_ item: RemoteFileItem, extending: Bool) {
        if extending {
            if selectedPaths.contains(item.path) {
                selectedPaths.remove(item.path)
            } else {
                selectedPaths.insert(item.path)
            }
        } else {
            selectedPaths = [item.path]
        }
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

    func copy(_ item: RemoteFileItem) {
        copy(actionItems(for: item))
    }

    func copy(_ items: [RemoteFileItem]) {
        copiedItems = uniqueItems(items)
        status = copiedItems.count == 1 ? "Copied \(copiedItems[0].name)" : "Copied \(copiedItems.count) items"
    }

    func paste(to remoteDirectory: String) {
        let itemsToPaste = copiedItems
        guard !itemsToPaste.isEmpty else {
            status = "Nothing to paste"
            return
        }

        let destinationDirectory = remoteDirectory
        if itemsToPaste.contains(where: { $0.isDirectory && (destinationDirectory == $0.path || destinationDirectory.hasPrefix($0.path + "/")) }) {
            status = "Cannot copy a folder into itself."
            return
        }

        uploadingPaths.insert(destinationDirectory)
        status = itemsToPaste.count == 1 ? "Copying \(itemsToPaste[0].name)..." : "Copying \(itemsToPaste.count) items..."

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: destinationDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                let copiedNames = itemsToPaste.map(\.name)
                if let duplicateName = Self.firstDuplicateName(copiedNames) {
                    result = .failure(RemoteFileError(message: "Multiple copied items are named \(duplicateName)."))
                } else if let existingName = copiedNames.first(where: { name in remoteItems.contains { $0.name == name } }) {
                    result = .failure(RemoteFileError(message: "An item named \(existingName) already exists."))
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
                    self.status = itemsToPaste.count == 1 ? "Pasted \(itemsToPaste[0].name)" : "Pasted \(itemsToPaste.count) items"
                    self.reloadAfterUpload(to: destinationDirectory)
                case .failure(let error):
                    self.status = "\(destinationDirectory): \(error.localizedDescription)"
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
            status = validation.message ?? "Invalid folder name"
            return false
        }

        uploadingPaths.insert(remoteDirectory)
        status = "Creating \(name)..."

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: remoteDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                if remoteItems.contains(where: { $0.name == name }) {
                    result = .failure(RemoteFileError(message: "An item named \(name) already exists."))
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
                    self.status = "Created \(name)"
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
            status = validation.message ?? "Invalid name"
            return false
        }

        guard newName != item.name else {
            return true
        }

        let newPath = Self.joined(Self.parentPath(item.path), newName)
        status = "Renaming \(item.name)..."

        Task.detached { [profile, sessionPassword] in
            let result = Self.renameItem(item, to: newPath, profile: profile, password: sessionPassword)

            await MainActor.run {
                switch result {
                case .success:
                    self.status = "Renamed \(item.name) to \(newName)"
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
        let itemsToDelete = uniqueItems(items)
        guard !itemsToDelete.isEmpty, confirmDelete(itemsToDelete) else {
            return
        }

        for item in itemsToDelete {
            movingPaths.insert(item.path)
        }
        status = itemsToDelete.count == 1 ? "Deleting \(itemsToDelete[0].name)..." : "Deleting \(itemsToDelete.count) items..."

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
                    self.status = itemsToDelete.count == 1 ? "Deleted \(itemsToDelete[0].name)" : "Deleted \(itemsToDelete.count) items"
                    self.reloadParents(of: itemsToDelete)
                case .failure(let error):
                    self.status = error.localizedDescription
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
        guard let destination = askDownloadDestination(for: item) else {
            return
        }

        downloadingPaths.insert(item.path)
        status = "Downloading \(item.name)..."

        Task.detached { [profile, sessionPassword] in
            let result = Self.downloadItem(item, to: destination, profile: profile, password: sessionPassword)

            await MainActor.run {
                self.downloadingPaths.remove(item.path)

                switch result {
                case .success:
                    self.status = "Downloaded \(item.name)"
                case .failure(let error):
                    self.status = "\(item.name): \(error.localizedDescription)"
                }
            }
        }
    }

    func download(_ items: [RemoteFileItem]) {
        let itemsToDownload = uniqueItems(items)
        guard !itemsToDownload.isEmpty,
              let destination = askDownloadDirectory() else {
            return
        }

        for item in itemsToDownload {
            downloadingPaths.insert(item.path)
        }
        status = "Downloading \(itemsToDownload.count) items..."

        Task.detached { [profile, sessionPassword] in
            let result = Self.downloadItems(itemsToDownload, toDirectory: destination, profile: profile, password: sessionPassword)

            await MainActor.run {
                for item in itemsToDownload {
                    self.downloadingPaths.remove(item.path)
                }

                switch result {
                case .success:
                    self.status = "Downloaded \(itemsToDownload.count) items"
                case .failure(let error):
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func dragItemProvider(for item: RemoteFileItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = Self.dragSuggestedName(for: item)
        let items = actionItems(for: item)
        draggedRemoteItems = items
        Self.sharedDragContext = RemoteDragContext(profile: profile, sessionPassword: sessionPassword, items: items)
        clearDraggedRemoteItemLater(item)

        let typeIdentifier = item.isDirectory
            ? UTType.folder.identifier
            : UTType(filenameExtension: (item.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier

        provider.registerFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { [profile, sessionPassword] completion in
            let progress = Progress(totalUnitCount: 1)

            Task.detached {
                let destination = Self.temporaryDragDestination(for: item)
                try? FileManager.default.removeItem(at: destination)

                let result = Self.downloadItem(item, to: destination, profile: profile, password: sessionPassword)

                switch result {
                case .success:
                    progress.completedUnitCount = 1
                    completion(destination, false, nil)
                case .failure(let error):
                    completion(nil, false, error)
                }
            }

            return progress
        }

        return provider
    }

    func chooseAndUpload(to remoteDirectory: String) {
        guard let urls = askUploadSources(), !urls.isEmpty else {
            return
        }

        upload(urls, to: remoteDirectory)
    }

    func handleDropProviders(_ providers: [NSItemProvider], to remoteDirectory: String) -> Bool {
        if !draggedRemoteItems.isEmpty {
            let items = draggedRemoteItems
            draggedRemoteItems = []
            Self.sharedDragContext = nil
            move(items, to: remoteDirectory)
            return true
        }

        if let dragContext = Self.sharedDragContext,
           dragContext.profile.id != profile.id {
            Self.sharedDragContext = nil
            copyFromRemote(dragContext, to: remoteDirectory)
            return true
        }

        let fileURLProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileURLProviders.isEmpty else {
            return false
        }

        for provider in fileURLProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.fileURL(from: item) else {
                    return
                }

                Task { @MainActor in
                    self.upload([url], to: remoteDirectory)
                }
            }
        }

        return true
    }

    private func clearDraggedRemoteItemLater(_ item: RemoteFileItem) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if draggedRemoteItems.contains(where: { $0.path == item.path }) {
                draggedRemoteItems = []
                Self.sharedDragContext = nil
            }
        }
    }

    private func copyFromRemote(_ context: RemoteDragContext, to remoteDirectory: String) {
        let itemsToCopy = uniqueItems(context.items)
        guard !itemsToCopy.isEmpty else {
            return
        }

        uploadingPaths.insert(remoteDirectory)
        status = itemsToCopy.count == 1 ? "Copying \(itemsToCopy[0].name)..." : "Copying \(itemsToCopy.count) items..."

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: remoteDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                let itemNames = itemsToCopy.map(\.name)
                if let duplicateName = Self.firstDuplicateName(itemNames) {
                    result = .failure(RemoteFileError(message: "Multiple copied items are named \(duplicateName)."))
                } else if let existingName = itemNames.first(where: { name in remoteItems.contains { $0.name == name } }) {
                    result = .failure(RemoteFileError(message: "An item named \(existingName) already exists."))
                } else {
                    result = Self.copyItemsThroughTemporaryDirectory(
                        itemsToCopy,
                        from: context.profile,
                        sourcePassword: context.sessionPassword,
                        to: remoteDirectory,
                        targetProfile: profile,
                        targetPassword: sessionPassword
                    )
                }
            case .failure(let error):
                result = .failure(error)
            }

            await MainActor.run {
                self.uploadingPaths.remove(remoteDirectory)

                switch result {
                case .success:
                    self.status = itemsToCopy.count == 1 ? "Copied \(itemsToCopy[0].name)" : "Copied \(itemsToCopy.count) items"
                    self.reloadAfterUpload(to: remoteDirectory)
                case .failure(let error):
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func move(_ item: RemoteFileItem, to remoteDirectory: String) {
        move([item], to: remoteDirectory)
    }

    private func move(_ items: [RemoteFileItem], to remoteDirectory: String) {
        let itemsToMove = uniqueItems(items)
        let destinationDirectory = remoteDirectory
        guard !itemsToMove.isEmpty else {
            return
        }

        if itemsToMove.allSatisfy({ Self.parentPath($0.path) == destinationDirectory }) {
            status = itemsToMove.count == 1 ? "\(itemsToMove[0].name) is already in this folder" : "Selected items are already in this folder"
            return
        }

        if itemsToMove.contains(where: { $0.isDirectory && (destinationDirectory == $0.path || destinationDirectory.hasPrefix($0.path + "/")) }) {
            status = "Cannot move a folder into itself."
            return
        }

        for item in itemsToMove {
            movingPaths.insert(item.path)
        }
        status = itemsToMove.count == 1 ? "Moving \(itemsToMove[0].name)..." : "Moving \(itemsToMove.count) items..."

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: destinationDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                let itemNames = itemsToMove.map(\.name)
                if let duplicateName = Self.firstDuplicateName(itemNames) {
                    result = .failure(RemoteFileError(message: "Multiple selected items are named \(duplicateName)."))
                } else if let existingName = itemNames.first(where: { name in remoteItems.contains { $0.name == name } }) {
                    result = .failure(RemoteFileError(message: "An item named \(existingName) already exists."))
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
                    self.status = itemsToMove.count == 1 ? "Moved \(itemsToMove[0].name)" : "Moved \(itemsToMove.count) items"
                    self.reloadParents(of: itemsToMove)
                    if self.expandedPaths.contains(destinationDirectory) || destinationDirectory == self.currentPath {
                        self.reloadAfterUpload(to: destinationDirectory)
                    }
                case .failure(let error):
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func upload(_ urls: [URL], to remoteDirectory: String) {
        if let message = Self.validateUploadSources(urls).message {
            status = message
            return
        }

        uploadingPaths.insert(remoteDirectory)
        status = urls.count == 1
            ? "Uploading \(urls[0].lastPathComponent)..."
            : "Uploading \(urls.count) items..."

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: remoteDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                if let message = Self.validateUploadSources(urls, existingItems: remoteItems).message {
                    result = .failure(RemoteFileError(message: message))
                } else {
                    result = Self.uploadItems(urls, to: remoteDirectory, profile: profile, password: sessionPassword)
                }
            case .failure(let error):
                result = .failure(error)
            }

            await MainActor.run {
                self.uploadingPaths.remove(remoteDirectory)

                switch result {
                case .success:
                    self.status = urls.count == 1
                        ? "Uploaded \(urls[0].lastPathComponent)"
                        : "Uploaded \(urls.count) items"
                    self.reloadAfterUpload(to: remoteDirectory)
                case .failure(let error):
                    self.status = "\(remoteDirectory): \(error.localizedDescription)"
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
            return NameValidation(name: name, message: "An item named \(name) already exists.")
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
            childrenByPath.removeValue(forKey: remoteDirectory)
            loadChildren(path: remoteDirectory)
        }
    }

    private func reloadParent(of item: RemoteFileItem) {
        let parent = Self.parentPath(item.path)
        if parent == currentPath {
            refresh()
        } else if expandedPaths.contains(parent) {
            childrenByPath.removeValue(forKey: parent)
            loadChildren(path: parent)
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
            childrenByPath.removeValue(forKey: parent)
            loadChildren(path: parent)
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

    private func loadChildren(path: String) {
        loadingPaths.insert(path)
        status = "Loading \(path)..."

        Task.detached { [profile, sessionPassword] in
            let result = Self.loadDirectory(profile: profile, path: path, password: sessionPassword)

            await MainActor.run {
                self.loadingPaths.remove(path)

                switch result {
                case .success(let items):
                    self.childrenByPath[path] = items
                    let visibleCount = self.visibleItems(items).count
                    self.status = visibleCount == 0 ? "\(path): Empty folder" : "\(path): \(visibleCount) items"
                case .failure(let error):
                    self.expandedPaths.remove(path)
                    self.status = "\(path): \(error.localizedDescription)"
                }
            }
        }
    }

    private nonisolated static func loadDirectory(profile: ServerProfile, path: String, password: String?) -> Result<[RemoteFileItem], RemoteFileError> {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SSHCommandBuilder.sftpArguments(for: profile, allowPassword: password != nil)
        process.environment = sftpEnvironment(password: password)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()

            let commands = sftpListCommands(for: path)
            input.fileHandleForWriting.write(Data(commands.utf8))
            try? input.fileHandleForWriting.close()

            guard waitForSFTPProcess(process) else {
                return .failure(RemoteFileError(message: "SFTP timed out"))
            }

            let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            _ = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            if process.terminationStatus == 0 {
                return .success(parseListing(outputText, basePath: path))
            } else {
                return loadDirectoryPlain(profile: profile, path: path, password: password)
            }
        } catch {
            return .failure(RemoteFileError(message: error.localizedDescription))
        }
    }

    private nonisolated static func downloadItem(_ item: RemoteFileItem, to destination: URL, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SSHCommandBuilder.sftpArguments(for: profile, allowPassword: password != nil)
        process.environment = sftpEnvironment(password: password)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()

            let command = item.isDirectory
                ? "get -R \(sftpQuoted(item.path)) \(sftpQuoted(destination.path))"
                : "get \(sftpQuoted(item.path)) \(sftpQuoted(destination.path))"
            let commands = """
            \(command)
            quit
            """

            input.fileHandleForWriting.write(Data(commands.utf8))
            try? input.fileHandleForWriting.close()
            guard waitForSFTPProcess(process) else {
                return .failure(RemoteFileError(message: "SFTP download timed out"))
            }

            let errorText = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            guard process.terminationStatus == 0 else {
                let message = [errorText, outputText]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(RemoteFileError(message: message.isEmpty ? "SFTP download failed" : message))
            }

            return .success(())
        } catch {
            return .failure(RemoteFileError(message: error.localizedDescription))
        }
    }

    private nonisolated static func downloadItems(_ items: [RemoteFileItem], toDirectory destination: URL, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        let commands = items.map { item in
            let option = item.isDirectory ? "-R " : ""
            return "get \(option)\(sftpQuoted(item.path)) \(sftpQuoted(destination.path))"
        }
        .joined(separator: "\n")

        return runSFTPCommands(commands, profile: profile, password: password, fallbackMessage: "SFTP download failed")
    }

    private nonisolated static func uploadItems(_ urls: [URL], to remoteDirectory: String, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        let commands = urls.map { url in
            let remoteTarget = joined(remoteDirectory, url.lastPathComponent)
            let option = isDirectory(url) ? "-R " : ""
            return "put \(option)\(sftpQuoted(url.path)) \(sftpQuoted(remoteTarget))"
        }
        .joined(separator: "\n")

        return runSFTPCommands(commands, profile: profile, password: password, fallbackMessage: "SFTP upload failed")
    }

    private nonisolated static func copyItems(_ items: [RemoteFileItem], to remoteDirectory: String, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        let sources = items.map { shellQuoted($0.path) }.joined(separator: " ")
        let command = "cp -R -- \(sources) \(shellQuoted(remoteDirectory))"
        return runRemoteCommand(command, profile: profile, password: password, fallbackMessage: "Remote copy failed")
    }

    private nonisolated static func copyItemsThroughTemporaryDirectory(
        _ items: [RemoteFileItem],
        from sourceProfile: ServerProfile,
        sourcePassword: String?,
        to remoteDirectory: String,
        targetProfile: ServerProfile,
        targetPassword: String?
    ) -> Result<Void, RemoteFileError> {
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

        switch downloadItems(items, toDirectory: temporaryDirectory, profile: sourceProfile, password: sourcePassword) {
        case .success:
            let localURLs = items.map { item in
                temporaryDirectory.appendingPathComponent(item.name, isDirectory: item.isDirectory)
            }
            return uploadItems(localURLs, to: remoteDirectory, profile: targetProfile, password: targetPassword)
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
                return NameValidation(name: name, message: "Multiple selected items are named \(name).")
            }

            guard !existingNames.contains(name) else {
                return NameValidation(name: name, message: "An item named \(name) already exists.")
            }

            names.insert(name)
        }

        return NameValidation(name: nil, message: nil)
    }

    private nonisolated static func validateRemoteName(_ proposedName: String) -> NameValidation {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            return NameValidation(name: nil, message: "Name cannot be empty.")
        }

        guard name != "." && name != ".." else {
            return NameValidation(name: name, message: "\(name) is not allowed.")
        }

        guard !name.contains("/") && !name.contains("\0") else {
            return NameValidation(name: name, message: "Name cannot contain / or null characters.")
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
        let commands = items.map { item in
            let newPath = joined(remoteDirectory, item.name)
            return "rename \(sftpQuoted(item.path)) \(sftpQuoted(newPath))"
        }
        .joined(separator: "\n")

        return runSFTPCommands(commands, profile: profile, password: password, fallbackMessage: "SFTP move failed")
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

        return runSFTPCommands(commands.joined(separator: "\n"), profile: profile, password: password, fallbackMessage: "SFTP delete failed")
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
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SSHCommandBuilder.sftpArguments(for: profile, allowPassword: password != nil)
        process.environment = sftpEnvironment(password: password)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()

            input.fileHandleForWriting.write(Data((commands + "\nquit\n").utf8))
            try? input.fileHandleForWriting.close()
            guard waitForSFTPProcess(process) else {
                return .failure(RemoteFileError(message: "\(fallbackMessage): timed out"))
            }

            let errorText = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            guard process.terminationStatus == 0 else {
                let message = [errorText, outputText]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(RemoteFileError(message: message.isEmpty ? fallbackMessage : message))
            }

            return .success(())
        } catch {
            return .failure(RemoteFileError(message: error.localizedDescription))
        }
    }

    private nonisolated static func runRemoteCommand(_ command: String, profile: ServerProfile, password: String?, fallbackMessage: String) -> Result<Void, RemoteFileError> {
        let process = Process()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHCommandBuilder.remoteCommandArguments(for: profile, command: command, allowPassword: password != nil)
        process.environment = sftpEnvironment(password: password)
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            guard waitForSFTPProcess(process) else {
                return .failure(RemoteFileError(message: "\(fallbackMessage): timed out"))
            }

            let errorText = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            guard process.terminationStatus == 0 else {
                let message = [errorText, outputText]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(RemoteFileError(message: message.isEmpty ? fallbackMessage : message))
            }

            return .success(())
        } catch {
            return .failure(RemoteFileError(message: error.localizedDescription))
        }
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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

    private nonisolated static func temporaryDragDestination(for item: RemoteFileItem) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrnithopterDragDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(item.name, isDirectory: item.isDirectory)
    }

    private nonisolated static func sftpEnvironment(password: String?) -> [String: String] {
        ProcessInfo.processInfo.environment
            .merging(SSHAskPass.environment(password: password)) { _, new in new }
    }

    private nonisolated static func waitForSFTPProcess(_ process: Process, timeout: TimeInterval = 20) -> Bool {
        guard process.isRunning else {
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
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

    private nonisolated static func loadDirectoryPlain(profile: ServerProfile, path: String, password: String?) -> Result<[RemoteFileItem], RemoteFileError> {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SSHCommandBuilder.sftpArguments(for: profile, allowPassword: password != nil)
        process.environment = sftpEnvironment(password: password)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            input.fileHandleForWriting.write(Data(sftpListCommands(for: path, decorated: false).utf8))
            try? input.fileHandleForWriting.close()
            guard waitForSFTPProcess(process) else {
                return .failure(RemoteFileError(message: "SFTP list timed out"))
            }

            let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let errorText = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            guard process.terminationStatus == 0 else {
                let message = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(RemoteFileError(message: message.isEmpty ? "SFTP list failed" : message))
            }

            return .success(parseListing(outputText, basePath: path))
        } catch {
            return .failure(RemoteFileError(message: error.localizedDescription))
        }
    }

    private nonisolated static func parseListing(_ output: String, basePath: String) -> [RemoteFileItem] {
        let detailedItems = output
            .split(separator: "\n")
            .compactMap { parseLongListingLine(String($0), basePath: basePath) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        if !detailedItems.isEmpty {
            return detailedItems
        }

        return output
            .split(separator: "\n")
            .compactMap { parseSimpleLine(String($0), basePath: basePath) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func parseLongListingLine(_ line: String, basePath: String) -> RemoteFileItem? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("sftp>"),
              !trimmed.hasPrefix("Connected to "),
              let permissions = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
              permissions.count >= 10 else {
            return nil
        }

        guard let type = permissions.first,
              type == "d" || type == "-" || type == "l" else {
            return nil
        }

        guard let name = filenameFromLongListing(trimmed) else {
            return nil
        }

        let displayName = name
            .components(separatedBy: " -> ")
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? name

        guard displayName != "." && displayName != ".." else {
            return nil
        }

        return RemoteFileItem(
            name: displayName,
            path: joined(basePath, displayName),
            isDirectory: type == "d"
        )
    }

    private nonisolated static func filenameFromLongListing(_ line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 9 else {
            return nil
        }

        return parts.dropFirst(8).joined(separator: " ")
    }

    private nonisolated static func parseSimpleLine(_ line: String, basePath: String) -> RemoteFileItem? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("sftp>"),
              !trimmed.hasPrefix("Connected to "),
              !trimmed.hasPrefix("Fetching "),
              !trimmed.hasPrefix("Changing "),
              !looksLikePermissionString(trimmed),
              trimmed != "." && trimmed != ".." else {
            return nil
        }

        let isDirectory = trimmed.hasSuffix("/")
        let name = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/*@=|"))
            .components(separatedBy: " -> ")
            .first ?? trimmed

        return RemoteFileItem(
            name: name,
            path: joined(basePath, name),
            isDirectory: isDirectory
        )
    }

    private nonisolated static func looksLikePermissionString(_ value: String) -> Bool {
        guard value.count >= 10 else {
            return false
        }

        let prefix = String(value.prefix(10))
        guard let first = prefix.first,
              ["d", "-", "l", "c", "b", "s", "p"].contains(first) else {
            return false
        }

        return prefix.dropFirst().allSatisfy { ["r", "w", "x", "s", "S", "t", "T", "-"].contains($0) }
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
            return "."
        }

        if path.hasPrefix("/") {
            return "/" + parts.dropLast().joined(separator: "/")
        }

        return parts.dropLast().joined(separator: "/")
    }

    private nonisolated static func sftpListCommands(for path: String, decorated: Bool = true) -> String {
        let lsCommand = decorated ? "ls -la" : "ls -1 -a"

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
        panel.title = "Download \(item.name)"
        panel.prompt = "Download"
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = item.isDirectory
            ? "Choose where to save this remote folder."
            : "Choose where to save this remote file."

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    private func askDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Download Selected Items"
        panel.prompt = "Download"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a local folder for the selected remote items."

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    private func askUploadSources() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Upload Files"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.message = "Choose local files or folders to upload."

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.urls
    }

    private func confirmDelete(_ item: RemoteFileItem) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(item.name)?"
        alert.informativeText = item.isDirectory
            ? "This will delete the remote folder and its contents."
            : "This will delete the remote file."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDelete(_ items: [RemoteFileItem]) -> Bool {
        guard items.count != 1 else {
            return confirmDelete(items[0])
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(items.count) items?"
        alert.informativeText = "This will delete the selected remote files and folders."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
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
    @State private var isDropTarget = false
    let collapseAction: () -> Void
    let editAction: (RemoteFileItem) -> Void

    init(
        profile: ServerProfile,
        sessionPassword: String? = nil,
        collapseAction: @escaping () -> Void,
        editAction: @escaping (RemoteFileItem) -> Void = { _ in }
    ) {
        _store = StateObject(wrappedValue: RemoteFileStore(profile: profile, sessionPassword: sessionPassword))
        self.collapseAction = collapseAction
        self.editAction = editAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Explorer")
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
                .help("Hide Explorer")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.isCreatingFolder(in: store.currentPath) {
                        NewFolderTreeRow(parentPath: store.currentPath, depth: 0, store: store)
                    }

                    ForEach(store.visibleItems(store.items)) { item in
                        RemoteFileTreeRow(
                            item: item,
                            depth: 0,
                            store: store,
                            supportedTextFilePatterns: supportedTextFilePatterns,
                            editAction: editAction
                        )
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isDropTarget ? Color.accentColor.opacity(0.14) : Color.clear)
                )
            }
            .onDrop(of: RemoteFileStore.acceptedDropTypes, isTargeted: $isDropTarget) { providers in
                store.handleDropProviders(providers, to: store.currentPath)
            }
            .contextMenu {
                Button {
                    store.newFolder(in: store.currentPath)
                } label: {
                    Label("New Folder...", systemImage: "folder.badge.plus")
                }

                Button {
                    store.paste(to: store.currentPath)
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .disabled(!store.hasCopiedItems)

                Divider()

                Button {
                    store.chooseAndUpload(to: store.currentPath)
                } label: {
                    Label("Upload Here...", systemImage: "arrow.up.circle")
                }
                .disabled(store.hasMultipleSelection)
            }

            Text(store.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .padding(10)
        }
        .frame(minWidth: 220)
        .task {
            store.refresh()
            await store.refreshAfterDelay(seconds: 3)
            await store.refreshAfterDelay(seconds: 7)
        }
    }
}

private struct RemoteFileTreeRow: View {
    let item: RemoteFileItem
    let depth: Int
    @ObservedObject var store: RemoteFileStore
    let supportedTextFilePatterns: String
    let editAction: (RemoteFileItem) -> Void
    @State private var isHovering = false
    @State private var isDropTarget = false
    @State private var isRenaming = false
    @State private var editedName = ""
    @FocusState private var renameFieldFocused: Bool

    private var uploadTarget: String {
        store.uploadTarget(for: item)
    }

    private var isEditableTextFile: Bool {
        AppPreferences.isTextEditableFile(item, patternsValue: supportedTextFilePatterns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if item.isDirectory {
                    Image(systemName: store.isExpanded(item) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Color.clear
                        .frame(width: 10, height: 10)
                }

                Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(item.isDirectory ? .blue : .secondary)
                    .frame(width: 16)
                    .opacity(item.isHidden ? 0.58 : 1)

                if isRenaming {
                    TextField("", text: $editedName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .frame(minHeight: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor, lineWidth: renameFieldFocused ? 1.5 : 1)
                        )
                        .focused($renameFieldFocused)
                        .onSubmit {
                            commitRename()
                        }
                        .onExitCommand {
                            cancelRename()
                        }
                } else {
                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(item.isHidden ? .secondary : .primary)
                        .opacity(item.isHidden ? 0.72 : 1)
                }

                Spacer(minLength: 0)

                if store.isUploading(to: uploadTarget) {
                    Image(systemName: "arrow.up.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else if store.isDownloading(item) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else if store.isMoving(item) {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else if store.isLoading(item) {
                    Image(systemName: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(rowBackgroundColor)
            )
            .padding(.horizontal, 4)
            .onHover { hovering in
                isHovering = hovering
            }
            .onTapGesture(count: 2) {
                if !isRenaming, isEditableTextFile {
                    store.select(item, extending: false)
                    editAction(item)
                }
            }
            .onTapGesture {
                if !isRenaming {
                    let isExtendingSelection = NSEvent.modifierFlags.contains(.command)
                    store.select(item, extending: isExtendingSelection)
                    if !isExtendingSelection {
                        store.open(item)
                    }
                }
            }
            .onDrag {
                store.dragItemProvider(for: item)
            }
            .onDrop(of: RemoteFileStore.acceptedDropTypes, isTargeted: $isDropTarget) { providers in
                store.handleDropProviders(providers, to: uploadTarget)
            }
            .contextMenu {
                if isEditableTextFile {
                    Button {
                        editAction(item)
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                    .disabled(store.actionItems(for: item).count > 1)

                    Divider()
                }

                Button {
                    store.copy(item)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    store.paste(to: uploadTarget)
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .disabled(!store.hasCopiedItems)

                Button {
                    store.newFolder(in: uploadTarget)
                } label: {
                    Label("New Folder...", systemImage: "folder.badge.plus")
                }

                Divider()

                Button {
                    store.chooseAndUpload(to: uploadTarget)
                } label: {
                    Label(item.isDirectory ? "Upload Here..." : "Upload...", systemImage: "arrow.up.circle")
                }
                .disabled(store.actionItems(for: item).count > 1)

                Button {
                    store.download(item)
                } label: {
                    Label("Download...", systemImage: "arrow.down.circle")
                }

                Button {
                    beginRename()
                } label: {
                    Label("Rename...", systemImage: "pencil")
                }
                .disabled(store.actionItems(for: item).count > 1)

                Button(role: .destructive) {
                    store.delete(item)
                } label: {
                    Label("Delete...", systemImage: "trash")
                }

                if item.isDirectory {
                    Button(store.isExpanded(item) ? "Collapse" : "Expand") {
                        store.open(item)
                    }
                }
            }
            .onChange(of: isRenaming) { _, renaming in
                guard renaming else {
                    return
                }

                DispatchQueue.main.async {
                    renameFieldFocused = true
                }
            }

            if item.isDirectory, store.isExpanded(item) {
                if store.isCreatingFolder(in: item.path) {
                    NewFolderTreeRow(parentPath: item.path, depth: depth + 1, store: store)
                }

                ForEach(store.children(for: item)) { child in
                    RemoteFileTreeRow(
                        item: child,
                        depth: depth + 1,
                        store: store,
                        supportedTextFilePatterns: supportedTextFilePatterns,
                        editAction: editAction
                    )
                }
            }
        }
    }

    private var rowBackgroundColor: Color {
        if isDropTarget {
            return Color.accentColor.opacity(0.24)
        }

        if store.isSelected(item) {
            return Color.accentColor.opacity(0.22)
        }

        if isHovering {
            return Color.accentColor.opacity(0.16)
        }

        return .clear
    }

    private func beginRename() {
        editedName = item.name
        isRenaming = true
    }

    private func commitRename() {
        if store.rename(item, to: editedName) {
            isRenaming = false
        }
    }

    private func cancelRename() {
        editedName = item.name
        isRenaming = false
    }
}

private struct NewFolderTreeRow: View {
    let parentPath: String
    let depth: Int
    @ObservedObject var store: RemoteFileStore
    @State private var folderName = "Untitled Folder"
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Color.clear
                .frame(width: 10, height: 10)

            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .frame(width: 16)

            TextField("", text: $folderName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .frame(minHeight: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: fieldFocused ? 1.5 : 1)
                )
                .focused($fieldFocused)
                .onSubmit {
                    commit()
                }
                .onExitCommand {
                    store.cancelNewFolder()
                }

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.10))
        )
        .padding(.horizontal, 4)
        .onAppear {
            DispatchQueue.main.async {
                fieldFocused = true
            }
        }
    }

    private func commit() {
        _ = store.createFolder(named: folderName, in: parentPath)
    }
}
