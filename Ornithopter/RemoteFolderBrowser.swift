//
//  RemoteFolderBrowser.swift
//  Ornithopter
//

import Combine
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
}

private struct RemoteFileError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
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
    @Published private(set) var status = "Not loaded"

    private let profile: ServerProfile

    init(profile: ServerProfile) {
        self.profile = profile
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

        Task.detached { [profile] in
            let result = Self.loadDirectory(profile: profile, path: path)

            await MainActor.run {
                switch result {
                case .success(let items):
                    if updateCurrentPath {
                        self.currentPath = path
                    }
                    self.items = items
                    self.childrenByPath[path] = items
                    self.status = items.isEmpty ? "Empty folder" : "\(items.count) items"
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
        childrenByPath[item.path] ?? []
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

    func uploadTarget(for item: RemoteFileItem) -> String {
        item.isDirectory ? item.path : Self.parentPath(item.path)
    }

    func rename(_ item: RemoteFileItem) {
        guard let newName = askRenameName(for: item) else {
            return
        }

        let newPath = Self.joined(Self.parentPath(item.path), newName)
        status = "Renaming \(item.name)..."

        Task.detached { [profile] in
            let result = Self.renameItem(item, to: newPath, profile: profile)

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
    }

    func delete(_ item: RemoteFileItem) {
        guard confirmDelete(item) else {
            return
        }

        status = "Deleting \(item.name)..."

        Task.detached { [profile] in
            let result = Self.deleteItem(item, profile: profile)

            await MainActor.run {
                switch result {
                case .success:
                    self.expandedPaths.remove(item.path)
                    self.childrenByPath.removeValue(forKey: item.path)
                    self.status = "Deleted \(item.name)"
                    self.reloadParent(of: item)
                case .failure(let error):
                    self.status = "\(item.name): \(error.localizedDescription)"
                }
            }
        }
    }

    func download(_ item: RemoteFileItem) {
        guard let destination = askDownloadDestination(for: item) else {
            return
        }

        downloadingPaths.insert(item.path)
        status = "Downloading \(item.name)..."

        Task.detached { [profile] in
            let result = Self.downloadItem(item, to: destination, profile: profile)

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

    func chooseAndUpload(to remoteDirectory: String) {
        guard let urls = askUploadSources(), !urls.isEmpty else {
            return
        }

        upload(urls, to: remoteDirectory)
    }

    func uploadFromDropProviders(_ providers: [NSItemProvider], to remoteDirectory: String) -> Bool {
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

    private func upload(_ urls: [URL], to remoteDirectory: String) {
        uploadingPaths.insert(remoteDirectory)
        status = urls.count == 1
            ? "Uploading \(urls[0].lastPathComponent)..."
            : "Uploading \(urls.count) items..."

        Task.detached { [profile] in
            let result = Self.uploadItems(urls, to: remoteDirectory, profile: profile)

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

    private func loadChildren(path: String) {
        loadingPaths.insert(path)
        status = "Loading \(path)..."

        Task.detached { [profile] in
            let result = Self.loadDirectory(profile: profile, path: path)

            await MainActor.run {
                self.loadingPaths.remove(path)

                switch result {
                case .success(let items):
                    self.childrenByPath[path] = items
                    self.status = items.isEmpty ? "\(path): Empty folder" : "\(path): \(items.count) items"
                case .failure(let error):
                    self.expandedPaths.remove(path)
                    self.status = "\(path): \(error.localizedDescription)"
                }
            }
        }
    }

    private nonisolated static func loadDirectory(profile: ServerProfile, path: String) -> Result<[RemoteFileItem], RemoteFileError> {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SSHCommandBuilder.sftpArguments(for: profile)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()

            let commands = sftpListCommands(for: path)
            input.fileHandleForWriting.write(Data(commands.utf8))
            try? input.fileHandleForWriting.close()

            process.waitUntilExit()

            let outputText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            _ = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            if process.terminationStatus == 0 {
                return .success(parseListing(outputText, basePath: path))
            } else {
                return loadDirectoryPlain(profile: profile, path: path)
            }
        } catch {
            return .failure(RemoteFileError(message: error.localizedDescription))
        }
    }

    private nonisolated static func downloadItem(_ item: RemoteFileItem, to destination: URL, profile: ServerProfile) -> Result<Void, RemoteFileError> {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SSHCommandBuilder.sftpArguments(for: profile)
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
            process.waitUntilExit()

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

    private nonisolated static func uploadItems(_ urls: [URL], to remoteDirectory: String, profile: ServerProfile) -> Result<Void, RemoteFileError> {
        let commands = urls.map { url in
            let remoteTarget = joined(remoteDirectory, url.lastPathComponent)
            let option = isDirectory(url) ? "-R " : ""
            return "put \(option)\(sftpQuoted(url.path)) \(sftpQuoted(remoteTarget))"
        }
        .joined(separator: "\n")

        return runSFTPCommands(commands, profile: profile, fallbackMessage: "SFTP upload failed")
    }

    private nonisolated static func renameItem(_ item: RemoteFileItem, to newPath: String, profile: ServerProfile) -> Result<Void, RemoteFileError> {
        runSFTPCommands(
            "rename \(sftpQuoted(item.path)) \(sftpQuoted(newPath))",
            profile: profile,
            fallbackMessage: "SFTP rename failed"
        )
    }

    private nonisolated static func deleteItem(_ item: RemoteFileItem, profile: ServerProfile) -> Result<Void, RemoteFileError> {
        if !item.isDirectory {
            return runSFTPCommands("rm \(sftpQuoted(item.path))", profile: profile, fallbackMessage: "SFTP delete failed")
        }

        switch recursiveDeleteCommands(for: item.path, profile: profile) {
        case .success(let commands):
            return runSFTPCommands(commands.joined(separator: "\n"), profile: profile, fallbackMessage: "SFTP delete failed")
        case .failure(let error):
            return .failure(error)
        }
    }

    private nonisolated static func recursiveDeleteCommands(for directory: String, profile: ServerProfile) -> Result<[String], RemoteFileError> {
        switch loadDirectory(profile: profile, path: directory) {
        case .success(let items):
            var commands: [String] = []

            for item in items {
                if item.isDirectory {
                    switch recursiveDeleteCommands(for: item.path, profile: profile) {
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

    private nonisolated static func runSFTPCommands(_ commands: String, profile: ServerProfile, fallbackMessage: String) -> Result<Void, RemoteFileError> {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SSHCommandBuilder.sftpArguments(for: profile)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()

            input.fileHandleForWriting.write(Data((commands + "\nquit\n").utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()

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

    private nonisolated static func loadDirectoryPlain(profile: ServerProfile, path: String) -> Result<[RemoteFileItem], RemoteFileError> {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = SSHCommandBuilder.sftpArguments(for: profile)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            input.fileHandleForWriting.write(Data(sftpListCommands(for: path, decorated: false).utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()

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

    private func askRenameName(for item: RemoteFileItem) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename \(item.name)"
        alert.informativeText = "Enter a new name for this remote item."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = item.name
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name, !newName.contains("/") else {
            return nil
        }

        return newName
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
    @State private var isDropTarget = false

    init(profile: ServerProfile) {
        _store = StateObject(wrappedValue: RemoteFileStore(profile: profile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EXPLORER")
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)

                Text(store.currentPath == "." ? "Home" : store.currentPath)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.items) { item in
                        RemoteFileTreeRow(item: item, depth: 0, store: store)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isDropTarget ? Color.accentColor.opacity(0.14) : Color.clear)
                )
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                store.uploadFromDropProviders(providers, to: store.currentPath)
            }
            .contextMenu {
                Button {
                    store.chooseAndUpload(to: store.currentPath)
                } label: {
                    Label("Upload Here...", systemImage: "arrow.up.circle")
                }
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
    @State private var isHovering = false
    @State private var isDropTarget = false

    private var uploadTarget: String {
        store.uploadTarget(for: item)
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

                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)

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
            .onTapGesture {
                store.open(item)
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                store.uploadFromDropProviders(providers, to: uploadTarget)
            }
            .contextMenu {
                Button {
                    store.chooseAndUpload(to: uploadTarget)
                } label: {
                    Label(item.isDirectory ? "Upload Here..." : "Upload to Parent...", systemImage: "arrow.up.circle")
                }

                Button {
                    store.download(item)
                } label: {
                    Label("Download...", systemImage: "arrow.down.circle")
                }

                Button {
                    store.rename(item)
                } label: {
                    Label("Rename...", systemImage: "pencil")
                }

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

            if item.isDirectory, store.isExpanded(item) {
                ForEach(store.children(for: item)) { child in
                    RemoteFileTreeRow(item: child, depth: depth + 1, store: store)
                }
            }
        }
    }

    private var rowBackgroundColor: Color {
        if isDropTarget {
            return Color.accentColor.opacity(0.24)
        }

        if isHovering {
            return Color.accentColor.opacity(0.16)
        }

        return .clear
    }
}
