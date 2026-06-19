//
//  ConnectionWindow.swift
//  Ornithopter
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SSHSessionWindowManager {
    private static var windows: [NSWindow] = []
    private static let initialWindowSize = NSSize(width: 1120, height: 720)
    private static let minimumWindowSize = NSSize(width: 920, height: 560)

    @discardableResult
    static func open(profile: ServerProfile) -> Bool {
        let sessionPassword = SSHPasswordPrompter.passwordForConnection(profile: profile)
        if profile.passwordAuthentication && sessionPassword == nil {
            return false
        }

        let controller = NSHostingController(
            rootView: ConnectionWindowView(profile: profile, sessionPassword: sessionPassword)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = profile.displayName
        window.titleVisibility = .visible
        window.setContentSize(initialWindowSize)
        window.minSize = minimumWindowSize
        window.contentMinSize = minimumWindowSize
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        windows.append(window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            windows.removeAll { $0 === window }
        }

        window.makeKeyAndOrderFront(nil)
        return true
    }
}

struct ConnectionWindowView: View {
    let profile: ServerProfile
    let sessionPassword: String?
    @AppStorage("defaultTextEditor") private var defaultTextEditor = AppPreferenceDefaults.textEditor
    @AppStorage("customTextEditor") private var customTextEditor = AppPreferenceDefaults.customTextEditor
    @State private var isExplorerVisible = true
    @State private var terminalLayout = TerminalLayout()
    @State private var activePaneID: TerminalPane.ID?

    var body: some View {
        HStack(spacing: 0) {
            if isExplorerVisible {
                RemoteFolderBrowser(
                    profile: profile,
                    sessionPassword: sessionPassword,
                    collapseAction: {
                        isExplorerVisible = false
                    },
                    editAction: { item in
                        openRemoteFileInEditor(item)
                    }
                )
                .frame(width: 240)
            } else {
                VStack {
                    Button {
                        isExplorerVisible = true
                    } label: {
                        Image(systemName: "sidebar.leading")
                    }
                    .buttonStyle(.borderless)
                    .help("Show Explorer")

                    Spacer()
                }
                .padding(.top, 8)
                .frame(width: 32)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            Divider()

            TerminalLayoutView(
                profile: profile,
                sessionPassword: sessionPassword,
                layout: terminalLayout,
                activePaneID: activePaneID,
                confirmReconnect: confirmReconnect,
                actions: TerminalLayoutActions(
                    activatePane: { activePaneID = $0 },
                    addSession: addSession,
                    closeSession: closeSession,
                    selectSession: selectSession,
                    splitPane: splitPane,
                    moveSession: moveSession,
                    reconnectSession: reconnectSession,
                    updateSessionTitle: updateSessionTitle
                )
            )
            .frame(minWidth: 620)
        }
        .frame(minWidth: 920, minHeight: 560)
        .onAppear {
            if activePaneID == nil {
                activePaneID = terminalLayout.firstPaneID
            }
        }
        .onDisappear {
            terminalLayout.terminateAll()
        }
    }

    private func confirmReconnect(status: Int32) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SSH connection closed"
        alert.informativeText = "The session ended unexpectedly with status \(status)."
        alert.addButton(withTitle: "Reconnect")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func addSession(to paneID: TerminalPane.ID) {
        terminalLayout.addSession(to: paneID)
        activePaneID = paneID
    }

    private func openRemoteFileInEditor(_ item: RemoteFileItem) {
        guard !item.isDirectory else {
            return
        }

        let editor = AppPreferences.effectiveTextEditor(defaultEditor: defaultTextEditor, customEditor: customTextEditor)
        let command = editorStartupCommand(editor: editor, path: item.path)
        let paneID = terminalLayout.validPaneID(preferred: activePaneID)
        terminalLayout.addSession(
            to: paneID,
            title: "\(editor) \(item.name)",
            startupCommand: command
        )
        activePaneID = paneID
    }

    private func editorStartupCommand(editor: String, path: String) -> String {
        let parent = parentPath(for: path)
        let filename = filename(for: path)
        let quotedParent = SSHCommandBuilder.shellQuotedArgument(parent)
        let quotedFilename = SSHCommandBuilder.shellQuotedArgument(filename)
        return "cd \(quotedParent) && \(editor) \(quotedFilename); exec \"${SHELL:-/bin/sh}\""
    }

    private func parentPath(for path: String) -> String {
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

    private func filename(for path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return parts.last ?? path
    }

    private func closeSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        terminalLayout.closeSession(sessionID, in: paneID)
        activePaneID = terminalLayout.validPaneID(preferred: paneID)
    }

    private func selectSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        terminalLayout.selectSession(sessionID, in: paneID)
        activePaneID = paneID
    }

    private func splitPane(_ paneID: TerminalPane.ID, axis: TerminalSplitAxis) {
        let previousAxis = terminalLayout.splitAxis
        terminalLayout.toggleSplit(axis)
        if previousAxis == axis {
            activePaneID = terminalLayout.primary.id
        } else if let secondaryPaneID = terminalLayout.secondary?.id {
            activePaneID = secondaryPaneID
        } else {
            activePaneID = paneID
        }
    }

    private func moveSession(_ sessionID: TerminalSession.ID, from sourcePaneID: TerminalPane.ID, to targetPaneID: TerminalPane.ID, before targetSessionID: TerminalSession.ID?) {
        terminalLayout.moveSession(sessionID, from: sourcePaneID, to: targetPaneID, before: targetSessionID)
        activePaneID = targetPaneID
    }

    private func reconnectSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        terminalLayout.reconnectSession(sessionID, in: paneID)
        activePaneID = paneID
    }

    private func updateSessionTitle(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID, title: String) {
        terminalLayout.updateSessionTitle(sessionID, in: paneID, title: displayTitle(from: title))
    }

    private func displayTitle(from rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }

        let userHostPrefix = "\(profile.username)@"
        if trimmed.hasPrefix(userHostPrefix) {
            let remotePart = trimmed.dropFirst(userHostPrefix.count)
            guard let separator = remotePart.firstIndex(where: { $0 == ":" || $0 == " " }) else {
                return "Terminal"
            }

            let suffix = remotePart[remotePart.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return compactTitleSuffix(suffix)
        }

        return String(trimmed.prefix(40))
    }

    private func compactTitleSuffix(_ suffix: String) -> String {
        guard !suffix.isEmpty else {
            return "Terminal"
        }

        let pathName = (suffix as NSString).lastPathComponent
        let displayName = pathName.isEmpty ? suffix : pathName
        return String(displayName.prefix(40))
    }
}

private struct TerminalSession: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var terminalID = UUID()
    var startupCommand: String?
    let runtime = TerminalSessionRuntime()

    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.terminalID == rhs.terminalID
            && lhs.startupCommand == rhs.startupCommand
    }
}

private struct TerminalPane: Identifiable, Equatable {
    let id = UUID()
    var sessions: [TerminalSession]
    var selectedSessionID: TerminalSession.ID?

    init(sessions: [TerminalSession] = [TerminalSession(title: "Terminal 1")]) {
        self.sessions = sessions
        selectedSessionID = sessions.first?.id
    }
}

private enum TerminalSplitAxis: Equatable {
    case horizontal
    case vertical
}

private struct TerminalLayout: Equatable {
    var primary = TerminalPane()
    var secondary: TerminalPane?
    var splitAxis: TerminalSplitAxis?

    var firstPaneID: TerminalPane.ID? {
        primary.id
    }

    mutating func toggleSplit(_ axis: TerminalSplitAxis) {
        if splitAxis == axis {
            collapseSplit()
            return
        }

        if secondary == nil {
            secondary = TerminalPane(sessions: [])
        }
        splitAxis = axis
    }

    private mutating func collapseSplit() {
        if let secondary {
            primary.sessions.append(contentsOf: secondary.sessions)
            if primary.selectedSessionID == nil {
                primary.selectedSessionID = primary.sessions.first?.id
            }
        }

        secondary = nil
        splitAxis = nil
    }

    mutating func addSession(to paneID: TerminalPane.ID, title: String? = nil, startupCommand: String? = nil) {
        updatePane(paneID) { pane in
            let nextNumber = (pane.sessions.map { Self.terminalNumber(from: $0.title) }.max() ?? 0) + 1
            let session = TerminalSession(
                title: title ?? "Terminal \(nextNumber)",
                startupCommand: startupCommand
            )
            pane.sessions.append(session)
            pane.selectedSessionID = session.id
        }
    }

    mutating func closeSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        updatePane(paneID) { pane in
            guard let index = pane.sessions.firstIndex(where: { $0.id == sessionID }) else {
                return
            }

            let wasSelected = pane.selectedSessionID == sessionID
            pane.sessions[index].runtime.terminate()
            pane.sessions.remove(at: index)

            if pane.sessions.isEmpty {
                pane.selectedSessionID = nil
            } else if wasSelected {
                let nextIndex = min(index, pane.sessions.count - 1)
                pane.selectedSessionID = pane.sessions[nextIndex].id
            }
        }

        collapseEmptySplitPane()
    }

    mutating func selectSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        updatePane(paneID) { pane in
            guard pane.sessions.contains(where: { $0.id == sessionID }) else {
                return
            }
            pane.selectedSessionID = sessionID
        }
    }

    mutating func reconnectSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        updateSession(sessionID, in: paneID) { session in
            session.runtime.reset()
            session.terminalID = UUID()
        }
    }

    mutating func updateSessionTitle(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID, title: String) {
        updateSession(sessionID, in: paneID) { session in
            session.title = title
        }
    }

    mutating func moveSession(_ sessionID: TerminalSession.ID, from sourcePaneID: TerminalPane.ID, to targetPaneID: TerminalPane.ID, before targetSessionID: TerminalSession.ID?) {
        guard sessionID != targetSessionID else {
            return
        }

        guard let session = removeSession(sessionID, from: sourcePaneID) else {
            return
        }

        updatePane(targetPaneID) { pane in
            if let targetSessionID,
               let targetIndex = pane.sessions.firstIndex(where: { $0.id == targetSessionID }) {
                pane.sessions.insert(session, at: targetIndex)
            } else {
                pane.sessions.append(session)
            }
            pane.selectedSessionID = session.id
        }
    }

    private mutating func removeSession(_ sessionID: TerminalSession.ID, from paneID: TerminalPane.ID) -> TerminalSession? {
        var removed: TerminalSession?
        updatePane(paneID) { pane in
            guard let index = pane.sessions.firstIndex(where: { $0.id == sessionID }) else {
                return
            }

            let wasSelected = pane.selectedSessionID == sessionID
            removed = pane.sessions.remove(at: index)

            if pane.sessions.isEmpty {
                pane.selectedSessionID = nil
            } else if wasSelected {
                let nextIndex = min(index, pane.sessions.count - 1)
                pane.selectedSessionID = pane.sessions[nextIndex].id
            }
        }
        return removed
    }

    private mutating func collapseEmptySplitPane() {
        guard splitAxis != nil, let secondary else {
            return
        }

        if primary.sessions.isEmpty {
            primary = secondary
            self.secondary = nil
            splitAxis = nil
        } else if secondary.sessions.isEmpty {
            self.secondary = nil
            splitAxis = nil
        }
    }

    func validPaneID(preferred paneID: TerminalPane.ID?) -> TerminalPane.ID {
        if primary.id == paneID {
            return primary.id
        }

        if let secondary, secondary.id == paneID {
            return secondary.id
        }

        return primary.id
    }

    private mutating func updateSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID, update: (inout TerminalSession) -> Void) {
        updatePane(paneID) { pane in
            guard let index = pane.sessions.firstIndex(where: { $0.id == sessionID }) else {
                return
            }
            update(&pane.sessions[index])
        }
    }

    private mutating func updatePane(_ paneID: TerminalPane.ID, update: (inout TerminalPane) -> Void) {
        if primary.id == paneID {
            update(&primary)
            return
        }

        guard var secondary, secondary.id == paneID else {
            return
        }

        update(&secondary)
        self.secondary = secondary
    }

    private static func terminalNumber(from title: String) -> Int {
        guard title.hasPrefix("Terminal ") else {
            return 0
        }
        return Int(title.dropFirst("Terminal ".count)) ?? 0
    }

    func terminateAll() {
        primary.sessions.forEach { $0.runtime.terminate() }
        secondary?.sessions.forEach { $0.runtime.terminate() }
    }
}

private struct TerminalLayoutActions {
    let activatePane: (TerminalPane.ID) -> Void
    let addSession: (TerminalPane.ID) -> Void
    let closeSession: (TerminalSession.ID, TerminalPane.ID) -> Void
    let selectSession: (TerminalSession.ID, TerminalPane.ID) -> Void
    let splitPane: (TerminalPane.ID, TerminalSplitAxis) -> Void
    let moveSession: (TerminalSession.ID, TerminalPane.ID, TerminalPane.ID, TerminalSession.ID?) -> Void
    let reconnectSession: (TerminalSession.ID, TerminalPane.ID) -> Void
    let updateSessionTitle: (TerminalSession.ID, TerminalPane.ID, String) -> Void
}

private struct TerminalDragContext {
    let paneID: TerminalPane.ID
    let sessionID: TerminalSession.ID
}

private enum TerminalTabDragStore {
    static let acceptedTypes: [UTType] = [.plainText]
    @MainActor static var context: TerminalDragContext?

    @MainActor
    static func begin(_ dragContext: TerminalDragContext) {
        context = dragContext
    }

    @MainActor
    static func clear() {
        context = nil
    }
}

private struct TerminalLayoutView: View {
    let profile: ServerProfile
    let sessionPassword: String?
    let layout: TerminalLayout
    let activePaneID: TerminalPane.ID?
    let confirmReconnect: (Int32) -> Bool
    let actions: TerminalLayoutActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()

                Button {
                    actions.splitPane(activePaneID ?? layout.primary.id, .horizontal)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
                .help(layout.splitAxis == .horizontal ? "Close split" : "Split right")

                Button {
                    actions.splitPane(activePaneID ?? layout.primary.id, .vertical)
                } label: {
                    Image(systemName: "rectangle.split.1x2")
                }
                .buttonStyle(.borderless)
                .help(layout.splitAxis == .vertical ? "Close split" : "Split down")
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if let splitAxis = layout.splitAxis, let secondary = layout.secondary {
                switch splitAxis {
                case .horizontal:
                    HSplitView {
                        paneView(layout.primary)
                        paneView(secondary)
                    }
                case .vertical:
                    VSplitView {
                        paneView(layout.primary)
                        paneView(secondary)
                    }
                }
            } else {
                paneView(layout.primary)
            }
        }
    }

    private func paneView(_ pane: TerminalPane) -> some View {
        TerminalPaneView(
            profile: profile,
            sessionPassword: sessionPassword,
            pane: pane,
            isActivePane: activePaneID == pane.id,
            confirmReconnect: confirmReconnect,
            actions: actions
        )
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
    }
}

private struct TerminalPaneView: View {
    let profile: ServerProfile
    let sessionPassword: String?
    let pane: TerminalPane
    let isActivePane: Bool
    let confirmReconnect: (Int32) -> Bool
    let actions: TerminalLayoutActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(pane.sessions) { session in
                            HStack(spacing: 6) {
                                Image(systemName: "terminal")
                                    .font(.caption)
                                Text(session.title)
                                    .lineLimit(1)

                                Button {
                                    actions.closeSession(session.id, pane.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 2)
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(tabBackground(for: session), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                actions.selectSession(session.id, pane.id)
                            }
                            .onDrag {
                                TerminalTabDragStore.begin(
                                    TerminalDragContext(
                                        paneID: pane.id,
                                        sessionID: session.id
                                    )
                                )
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .ownProcess) { completion in
                                    completion(Data(session.id.uuidString.utf8), nil)
                                    return nil
                                }
                                return provider
                            } preview: {
                                Text("I")
                                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .frame(width: 10, height: 28)
                            }
                            .onDrop(of: TerminalTabDragStore.acceptedTypes, isTargeted: nil) { _ in
                                handleDrop(before: session.id)
                            }
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
                }
                .onDrop(of: TerminalTabDragStore.acceptedTypes, isTargeted: nil) { _ in
                    handleDrop(before: nil)
                }

                Button {
                    actions.addSession(pane.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New terminal tab")
                .padding(.horizontal, 8)
            }
            .frame(height: 36)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if !pane.sessions.isEmpty {
                ZStack {
                    ForEach(pane.sessions) { session in
                        TerminalTextView(
                            profile: profile,
                            sessionPassword: sessionPassword,
                            runtime: session.runtime,
                            isActive: isActivePane && session.id == pane.selectedSessionID,
                            startupCommand: session.startupCommand,
                            onRunningChanged: { _ in },
                            onUnexpectedExit: { status in
                                DispatchQueue.main.async {
                                    if confirmReconnect(status) {
                                        actions.reconnectSession(session.id, pane.id)
                                    }
                                }
                            },
                            onTitleChanged: { title in
                                actions.updateSessionTitle(session.id, pane.id, title)
                            }
                        )
                        .id(session.terminalID)
                        .opacity(session.id == pane.selectedSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == pane.selectedSessionID)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Terminal", systemImage: "terminal")
                } description: {
                    Text("Add a terminal tab to start a session.")
                } actions: {
                    Button {
                        actions.addSession(pane.id)
                    } label: {
                        Label("New Terminal", systemImage: "plus")
                    }
                }
                .onDrop(of: TerminalTabDragStore.acceptedTypes, isTargeted: nil) { _ in
                    handleDrop(before: nil)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: TerminalTabDragStore.acceptedTypes, isTargeted: nil) { _ in
            handleDrop(before: nil)
        }
        .onTapGesture {
            actions.activatePane(pane.id)
        }
    }

    private func tabBackground(for session: TerminalSession) -> Color {
        session.id == pane.selectedSessionID
            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
            : Color.clear
    }

    private func handleDrop(before targetSessionID: TerminalSession.ID?) -> Bool {
        guard let context = TerminalTabDragStore.context else {
            return false
        }

        TerminalTabDragStore.clear()
        actions.moveSession(context.sessionID, context.paneID, pane.id, targetSessionID)
        return true
    }
}
