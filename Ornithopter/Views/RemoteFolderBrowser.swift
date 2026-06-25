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

private nonisolated struct RemoteSubprocessResult {
    let outputText: String
    let errorText: String
    let terminationStatus: Int32
}

private nonisolated final class RemoteProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func start(readingFrom fileHandle: FileHandle) {
        fileHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                return
            }

            self?.append(chunk)
        }
    }

    func stop(readingFrom fileHandle: FileHandle) {
        fileHandle.readabilityHandler = nil
    }

    func finish(readingFrom fileHandle: FileHandle) -> String {
        fileHandle.readabilityHandler = nil
        append(fileHandle.readDataToEndOfFile())

        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    private func append(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }

        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
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
    @Published private(set) var status = NSLocalizedString("Not loaded", comment: "")

    static let acceptedDropTypes: [UTType] = [.item, .fileURL]

    private let profile: ServerProfile
    private let sessionPassword: String?

    private nonisolated static func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private nonisolated static func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }

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
        status = Self.localized("Loading...")
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
                    self.status = visibleCount == 0
                        ? Self.localized("Empty folder")
                        : Self.localizedFormat("%d items", visibleCount)
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
            selectedPaths.removeAll()
            selectedPaths.insert(item.path)
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
        let itemsToDelete = uniqueItems(items)
        guard !itemsToDelete.isEmpty, confirmDelete(itemsToDelete) else {
            return
        }

        for item in itemsToDelete {
            movingPaths.insert(item.path)
        }
        status = itemsToDelete.count == 1
            ? Self.localizedFormat("Deleting %@...", itemsToDelete[0].name)
            : Self.localizedFormat("Deleting %d items...", itemsToDelete.count)

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
        status = Self.localizedFormat("Downloading %@...", item.name)

        Task.detached { [profile, sessionPassword] in
            let result = Self.downloadItem(item, to: destination, profile: profile, password: sessionPassword)

            await MainActor.run {
                self.downloadingPaths.remove(item.path)

                switch result {
                case .success:
                    self.status = Self.localizedFormat("Downloaded %@", item.name)
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
        status = Self.localizedFormat("Downloading %d items...", itemsToDownload.count)

        Task.detached { [profile, sessionPassword] in
            let result = Self.downloadItems(itemsToDownload, toDirectory: destination, profile: profile, password: sessionPassword)

            await MainActor.run {
                for item in itemsToDownload {
                    self.downloadingPaths.remove(item.path)
                }

                switch result {
                case .success:
                    self.status = Self.localizedFormat("Downloaded %d items", itemsToDownload.count)
                case .failure(let error):
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func dragItemProvider(for item: RemoteFileItem) -> NSItemProvider {
        let provider = NSItemProvider()
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
        ) { [profile, sessionPassword] completion in
            let progress = Progress(totalUnitCount: 1)

            Task.detached {
                let destination = Self.temporaryDragDestination(for: items, draggedItem: item)
                try? FileManager.default.removeItem(at: destination)

                let result = Self.downloadDragItems(items, to: destination, profile: profile, password: sessionPassword)

                switch result {
                case .success:
                    progress.completedUnitCount = 1
                    completion(destination, false, nil)
                case .failure(let error):
                    completion(nil, false, error)
                }

                Task { @MainActor in
                    AppDragRegistry.clearActiveRemoteFileDrag(token)
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

    func uploadDroppedURLs(_ urls: [URL], to remoteDirectory: String) {
        upload(urls, to: remoteDirectory)
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

    private func copyFromRemote(_ context: RemoteFileDragPayload, to remoteDirectory: String) {
        let itemsToCopy = uniqueItems(context.items)
        guard !itemsToCopy.isEmpty else {
            return
        }

        uploadingPaths.insert(remoteDirectory)
        status = itemsToCopy.count == 1
            ? Self.localizedFormat("Copying %@...", itemsToCopy[0].name)
            : Self.localizedFormat("Copying %d items...", itemsToCopy.count)

        Task.detached { [profile, sessionPassword] in
            let result: Result<Void, RemoteFileError>
            switch Self.loadDirectory(profile: profile, path: remoteDirectory, password: sessionPassword) {
            case .success(let remoteItems):
                let itemNames = itemsToCopy.map(\.name)
                if let duplicateName = Self.firstDuplicateName(itemNames) {
                    result = .failure(RemoteFileError(message: Self.localizedFormat("Multiple copied items are named %@.", duplicateName)))
                } else if let existingName = itemNames.first(where: { name in remoteItems.contains { $0.name == name } }) {
                    result = .failure(RemoteFileError(message: Self.localizedFormat("An item named %@ already exists.", existingName)))
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
                    self.status = itemsToCopy.count == 1
                        ? Self.localizedFormat("Copied %@", itemsToCopy[0].name)
                        : Self.localizedFormat("Copied %d items", itemsToCopy.count)
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
            ? Self.localizedFormat("Uploading %@...", urls[0].lastPathComponent)
            : Self.localizedFormat("Uploading %d items...", urls.count)

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
                        ? Self.localizedFormat("Uploaded %@", urls[0].lastPathComponent)
                        : Self.localizedFormat("Uploaded %d items", urls.count)
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
        status = Self.localizedFormat("Loading %@...", path)

        Task.detached { [profile, sessionPassword] in
            let result = Self.loadDirectory(profile: profile, path: path, password: sessionPassword)

            await MainActor.run {
                self.loadingPaths.remove(path)

                switch result {
                case .success(let items):
                    self.childrenByPath[path] = items
                    let visibleCount = self.visibleItems(items).count
                    self.status = visibleCount == 0
                        ? Self.localizedFormat("%@: Empty folder", path)
                        : Self.localizedFormat("%@: %d items", path, visibleCount)
                case .failure(let error):
                    self.expandedPaths.remove(path)
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
                return .success(parseListing(subprocessResult.outputText, basePath: path))
            } else {
                return loadDirectoryPlain(profile: profile, path: path, password: password)
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func downloadItem(_ item: RemoteFileItem, to destination: URL, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
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

    private nonisolated static func downloadItems(_ items: [RemoteFileItem], toDirectory destination: URL, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        let commands = items.map { item in
            let option = item.isDirectory ? "-R " : ""
            return "get \(option)\(sftpQuoted(item.path)) \(sftpQuoted(destination.path))"
        }
        .joined(separator: "\n")

        return runSFTPCommands(commands, profile: profile, password: password, fallbackMessage: "SFTP download failed")
    }

    private nonisolated static func downloadDragItems(_ items: [RemoteFileItem], to destination: URL, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        guard items.count > 1 else {
            guard let item = items.first else {
                return .failure(RemoteFileError(message: localized("Nothing to download")))
            }

            return downloadItem(item, to: destination, profile: profile, password: password)
        }

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return .failure(RemoteFileError(message: error.localizedDescription))
        }

        return downloadItems(items, toDirectory: destination, profile: profile, password: password)
    }

    private nonisolated static func uploadItems(_ urls: [URL], to remoteDirectory: String, profile: ServerProfile, password: String?) -> Result<Void, RemoteFileError> {
        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        }

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
        let askPassSession = SSHAskPassSession(password: password)
        defer {
            askPassSession?.stop()
        }

        let result = runProcess(
            executablePath: "/usr/bin/ssh",
            arguments: SSHCommandBuilder.remoteCommandArguments(for: profile, command: command, allowPassword: password != nil),
            environment: remoteProcessEnvironment(askPassSession: askPassSession),
            input: nil,
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
        timeoutMessage: String
    ) -> Result<RemoteSubprocessResult, RemoteFileError> {
        let process = Process()
        let inputPipe = input.map { _ in Pipe() }
        let output = Pipe()
        let errorPipe = Pipe()
        let outputCollector = RemoteProcessOutputCollector()
        let errorCollector = RemoteProcessOutputCollector()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = output
        process.standardError = errorPipe

        do {
            try process.run()
            outputCollector.start(readingFrom: output.fileHandleForReading)
            errorCollector.start(readingFrom: errorPipe.fileHandleForReading)

            if let input, let inputPipe {
                inputPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inputPipe.fileHandleForWriting.close()
            }

            guard waitForSFTPProcess(process) else {
                outputCollector.stop(readingFrom: output.fileHandleForReading)
                errorCollector.stop(readingFrom: errorPipe.fileHandleForReading)
                return .failure(RemoteFileError(message: timeoutMessage))
            }

            return .success(
                RemoteSubprocessResult(
                    outputText: outputCollector.finish(readingFrom: output.fileHandleForReading),
                    errorText: errorCollector.finish(readingFrom: errorPipe.fileHandleForReading),
                    terminationStatus: process.terminationStatus
                )
            )
        } catch {
            outputCollector.stop(readingFrom: output.fileHandleForReading)
            errorCollector.stop(readingFrom: errorPipe.fileHandleForReading)
            try? inputPipe?.fileHandleForWriting.close()
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

    private nonisolated static func waitForSFTPProcess(_ process: Process, timeout: TimeInterval = 20) -> Bool {
        guard process.isRunning else {
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

    private nonisolated static func loadDirectoryPlain(profile: ServerProfile, path: String, password: String?) -> Result<[RemoteFileItem], RemoteFileError> {
        let result = runSFTPProcess(
            input: sftpListCommands(for: path, decorated: false),
            profile: profile,
            password: password,
            timeoutMessage: localized("SFTP list timed out")
        )

        switch result {
        case .success(let subprocessResult):
            guard subprocessResult.terminationStatus == 0 else {
                let message = subprocessResult.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(RemoteFileError(message: message.isEmpty ? "SFTP list failed" : message))
            }

            return .success(parseListing(subprocessResult.outputText, basePath: path))
        case .failure(let error):
            return .failure(error)
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
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.clearSelection()
                    }
            )
            .onDrop(of: RemoteFileStore.acceptedDropTypes, isTargeted: $isDropTarget) { providers in
                store.handleDropProviders(providers, to: store.currentPath)
            }
            .onExitCommand {
                store.clearSelection()
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
        .background(EscapeKeyHandler(action: store.clearSelection))
        .task {
            store.refresh()
            await store.refreshAfterDelay(seconds: 3)
            await store.refreshAfterDelay(seconds: 7)
        }
    }
}

private struct EscapeKeyHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> EscapeKeyHandlerView {
        let view = EscapeKeyHandlerView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: EscapeKeyHandlerView, context: Context) {
        nsView.action = action
    }
}

private final class EscapeKeyHandlerView: NSView {
    var action: () -> Void = {}
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else {
            return
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            if event.keyCode == 53, self.window?.isKeyWindow == true {
                self.action()
            }

            return event
        }
    }
}

private struct RowClickCaptureView: NSViewRepresentable {
    struct Click {
        let modifierFlags: NSEvent.ModifierFlags
        let clickCount: Int
    }

    let action: (Click) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> RowClickCaptureNSView {
        let view = RowClickCaptureNSView()
        context.coordinator.view = view
        context.coordinator.installMonitorsIfNeeded()
        return view
    }

    func updateNSView(_ nsView: RowClickCaptureNSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.action = action
        context.coordinator.installMonitorsIfNeeded()
    }

    final class Coordinator {
        var action: (Click) -> Void
        weak var view: RowClickCaptureNSView?
        private var mouseDownMonitor: Any?
        private var mouseUpMonitor: Any?
        private var mouseDownLocation: NSPoint?
        private var mouseDownModifierFlags: NSEvent.ModifierFlags = []

        init(action: @escaping (Click) -> Void) {
            self.action = action
        }

        func installMonitorsIfNeeded() {
            guard mouseDownMonitor == nil, mouseUpMonitor == nil else {
                return
            }

            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleMouseDown(event)
                return event
            }
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.handleMouseUp(event)
                return event
            }
        }

        private func handleMouseDown(_ event: NSEvent) {
            guard contains(event) else {
                mouseDownLocation = nil
                return
            }

            mouseDownLocation = event.locationInWindow
            mouseDownModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        }

        private func handleMouseUp(_ event: NSEvent) {
            guard let mouseDownLocation else {
                return
            }

            defer {
                self.mouseDownLocation = nil
            }

            let distance = hypot(event.locationInWindow.x - mouseDownLocation.x, event.locationInWindow.y - mouseDownLocation.y)
            guard distance <= 4, contains(event) else {
                return
            }

            action(
                Click(
                    modifierFlags: mouseDownModifierFlags,
                    clickCount: event.clickCount
                )
            )
        }

        private func contains(_ event: NSEvent) -> Bool {
            guard let view,
                  event.window === view.window else {
                return false
            }

            let location = view.convert(event.locationInWindow, from: nil)
            return view.bounds.contains(location)
        }

        deinit {
            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
            }
            if let mouseUpMonitor {
                NSEvent.removeMonitor(mouseUpMonitor)
            }
        }
    }
}

private final class RowClickCaptureNSView: NSView {
    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct LocalFileDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let action: ([URL]) -> Void
    let remoteAction: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isTargeted: $isTargeted, action: action, remoteAction: remoteAction)
    }

    func makeNSView(context: Context) -> LocalFileDropTargetView {
        let view = LocalFileDropTargetView()
        view.coordinator = context.coordinator
        view.registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType(UTType.item.identifier)])
        return view
    }

    func updateNSView(_ nsView: LocalFileDropTargetView, context: Context) {
        context.coordinator.isTargeted = $isTargeted
        context.coordinator.action = action
        context.coordinator.remoteAction = remoteAction
        nsView.coordinator = context.coordinator
    }

    final class Coordinator {
        var isTargeted: Binding<Bool>
        var action: ([URL]) -> Void
        var remoteAction: () -> Bool

        init(isTargeted: Binding<Bool>, action: @escaping ([URL]) -> Void, remoteAction: @escaping () -> Bool) {
            self.isTargeted = isTargeted
            self.action = action
            self.remoteAction = remoteAction
        }
    }
}

private final class LocalFileDropTargetView: NSView {
    weak var coordinator: LocalFileDropTarget.Coordinator?

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDragged, .leftMouseUp:
            return self
        default:
            return nil
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isInternalRemoteDrag(sender) {
            coordinator?.isTargeted.wrappedValue = true
            return .move
        }

        guard !localFileURLs(from: sender).isEmpty else {
            return []
        }

        coordinator?.isTargeted.wrappedValue = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isInternalRemoteDrag(sender) {
            return .move
        }

        return localFileURLs(from: sender).isEmpty ? NSDragOperation() : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        coordinator?.isTargeted.wrappedValue = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isInternalRemoteDrag(sender) {
            coordinator?.isTargeted.wrappedValue = false
            return coordinator?.remoteAction() ?? false
        }

        let urls = localFileURLs(from: sender)
        coordinator?.isTargeted.wrappedValue = false
        guard !urls.isEmpty else {
            return false
        }

        coordinator?.action(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        coordinator?.isTargeted.wrappedValue = false
    }

    private func localFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let pasteboard = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            (object as? URL) ?? (object as? NSURL).map { $0 as URL }
        }
    }

    private func isInternalRemoteDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource != nil && AppDragRegistry.activeRemoteFilePayload != nil
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

    private var itemIconName: String {
        if item.isDirectory {
            return "folder.fill"
        }

        return isEditableTextFile ? "doc.text" : "doc"
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

                Image(systemName: itemIconName)
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
            .background(
                RowClickCaptureView { click in
                    handleRowClick(click)
                }
            )
            .onDrag {
                store.dragItemProvider(for: item)
            }
            .onDrop(of: RemoteFileStore.acceptedDropTypes, isTargeted: $isDropTarget) { providers in
                store.handleDropProviders(providers, to: uploadTarget)
            }
            .overlay(
                LocalFileDropTarget(isTargeted: $isDropTarget) { urls in
                    store.uploadDroppedURLs(urls, to: uploadTarget)
                } remoteAction: {
                    store.handleActiveRemoteFileDrop(to: uploadTarget)
                }
            )
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

    private func handleRowClick(_ click: RowClickCaptureView.Click) {
        guard !isRenaming else {
            return
        }

        if click.clickCount >= 2 {
            guard item.isDirectory || isEditableTextFile else {
                return
            }

            store.select(item, extending: false)
            editAction(item)
            return
        }

        let isExtendingSelection = click.modifierFlags.contains(.command)
        store.select(item, extending: isExtendingSelection)
        if !isExtendingSelection {
            store.open(item)
        }
    }

    private var rowBackgroundColor: Color {
        if isDropTarget {
            return Color.accentColor.opacity(0.24)
        }

        if store.isSelected(item) {
            return Color.accentColor.opacity(0.28)
        }

        if isHovering {
            return Color.primary.opacity(0.08)
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
