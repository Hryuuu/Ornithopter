//
//  ConnectionWindow.swift
//  Ornithopter
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SSHSessionWindowManager {
    private static var windows: [NSWindow] = []
    private static var windowsByID: [UUID: NSWindow] = [:]
    private static var windowDelegates: [UUID: TerminalWindowDelegate] = [:]
    private static var registrations: [UUID: TerminalWindowRegistration] = [:]
    private static let initialWindowSize = NSSize(width: 1120, height: 720)
    private static let minimumWindowSize = NSSize(width: 920, height: 560)

    @discardableResult
    static func open(profile: ServerProfile, keychainSavingEnabled: ((ServerProfile.ID) -> Void)? = nil) -> Bool {
        openWindow(profile: profile, keychainSavingEnabled: keychainSavingEnabled)
    }

    @discardableResult
    private static func openWindow(
        profile: ServerProfile,
        sessionPassword providedPassword: String? = nil,
        initialSession: TerminalSession? = nil,
        at screenPoint: NSPoint? = nil,
        keychainSavingEnabled: ((ServerProfile.ID) -> Void)? = nil
    ) -> Bool {
        let passwordResult = providedPassword.map {
            SSHConnectionPasswordResult(password: $0, shouldEnableKeychainSaving: false)
        } ?? SSHPasswordPrompter.passwordForConnection(profile: profile)
        let sessionPassword = passwordResult?.password
        if profile.passwordAuthentication && sessionPassword == nil {
            return false
        }

        if passwordResult?.shouldEnableKeychainSaving == true {
            keychainSavingEnabled?(profile.id)
        }

        let windowID = UUID()
        let controller = NSHostingController(
            rootView: ConnectionWindowView(
                windowID: windowID,
                profile: profile,
                sessionPassword: sessionPassword,
                initialSession: initialSession
            )
        )
        let window = NSWindow(contentViewController: controller)
        window.title = profile.displayName
        window.titleVisibility = .visible
        window.setContentSize(initialWindowSize)
        window.minSize = minimumWindowSize
        window.contentMinSize = minimumWindowSize
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        if let screenPoint {
            window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 80, y: screenPoint.y + 40))
        } else {
            window.center()
        }
        windows.append(window)
        windowsByID[windowID] = window
        let windowDelegate = TerminalWindowDelegate(windowID: windowID)
        window.delegate = windowDelegate
        windowDelegates[windowID] = windowDelegate

        windowDelegate.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            cleanupWindow(id: windowID, window: window)
        }

        window.makeKeyAndOrderFront(nil)
        return true
    }

    private static func cleanupWindow(id: UUID, window: NSWindow?) {
        let existingWindow = windowsByID[id]
        registrations[id]?.closeAllSessions()
        registrations[id] = nil
        windowsByID[id] = nil
        windowDelegates[id] = nil
        if let window = window ?? existingWindow {
            windows.removeAll { $0 === window }
        }
    }

    fileprivate static func registerWindow(
        id: UUID,
        profile: ServerProfile,
        sessionPassword: String?,
        detachSession: @escaping (TerminalPane.ID, TerminalSession.ID) -> TerminalSession?,
        insertSession: @escaping (TerminalSession, TerminalPane.ID, TerminalSession.ID?) -> Void,
        showDropError: @escaping (String) -> Void,
        updateSessionRunning: @escaping (TerminalSession.ID, Bool) -> Bool,
        scheduleNormalExitClose: @escaping (TerminalSession.ID) -> Bool,
        handleUnexpectedExit: @escaping (TerminalSession.ID, Int32) -> Bool,
        updateSessionTitle: @escaping (TerminalSession.ID, String) -> Bool,
        hasRunningSessions: @escaping () -> Bool,
        closeAllSessions: @escaping () -> Void
    ) {
        registrations[id] = TerminalWindowRegistration(
            profile: profile,
            sessionPassword: sessionPassword,
            detachSession: detachSession,
            insertSession: insertSession,
            showDropError: showDropError,
            updateSessionRunning: updateSessionRunning,
            scheduleNormalExitClose: scheduleNormalExitClose,
            handleUnexpectedExit: handleUnexpectedExit,
            updateSessionTitle: updateSessionTitle,
            hasRunningSessions: hasRunningSessions,
            closeAllSessions: closeAllSessions
        )
    }

    fileprivate static func unregisterWindow(id: UUID) {
        registrations[id] = nil
    }

    fileprivate static func moveTerminalSession(_ context: TerminalDragContext, to targetWindowID: UUID, targetPaneID: TerminalPane.ID, before targetSessionID: TerminalSession.ID?) -> Bool {
        guard context.windowID != targetWindowID else {
            return false
        }

        guard let source = registrations[context.windowID],
              let target = registrations[targetWindowID] else {
            return false
        }

        guard source.profile.id == target.profile.id else {
            target.showDropError(NSLocalizedString("Cannot move terminal tab to a different server.", comment: "terminal tab cross-server drop error"))
            return true
        }

        guard let session = source.detachSession(context.paneID, context.sessionID) else {
            return false
        }

        target.insertSession(session, targetPaneID, targetSessionID)
        return true
    }

    fileprivate static func detachTerminalSessionToNewWindow(_ context: TerminalDragContext, at screenPoint: NSPoint) {
        guard let source = registrations[context.windowID],
              let session = source.detachSession(context.paneID, context.sessionID) else {
            return
        }

        if !openWindow(profile: source.profile, sessionPassword: source.sessionPassword, initialSession: session, at: screenPoint) {
            source.insertSession(session, context.paneID, nil)
        }
    }

    fileprivate static func isPointInsideSessionWindow(_ screenPoint: NSPoint) -> Bool {
        windowsByID.values.contains { window in
            window.isVisible && window.frame.contains(screenPoint)
        }
    }

    fileprivate static func shouldCloseWindow(id: UUID) -> Bool {
        guard registrations[id]?.hasRunningSessions() == true else {
            return true
        }

        return confirmCloseWindowWithOpenSessions()
    }

    fileprivate static func updateTerminalSessionRunning(_ sessionID: TerminalSession.ID, isRunning: Bool) {
        for registration in registrations.values where registration.updateSessionRunning(sessionID, isRunning) {
            return
        }
    }

    fileprivate static func scheduleNormalExitClose(_ sessionID: TerminalSession.ID) {
        for registration in registrations.values where registration.scheduleNormalExitClose(sessionID) {
            return
        }
    }

    fileprivate static func handleUnexpectedExit(_ sessionID: TerminalSession.ID, status: Int32) {
        for registration in registrations.values where registration.handleUnexpectedExit(sessionID, status) {
            return
        }
    }

    fileprivate static func updateTerminalSessionTitle(_ sessionID: TerminalSession.ID, title: String) {
        for registration in registrations.values where registration.updateSessionTitle(sessionID, title) {
            return
        }
    }

    private static func confirmCloseWindowWithOpenSessions() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Close this SSH window?", comment: "SSH window close confirmation title")
        alert.informativeText = NSLocalizedString(
            "Open terminal tabs will receive an exit command and disconnect.",
            comment: "SSH window close confirmation message"
        )
        alert.addButton(withTitle: NSLocalizedString("Close Window", comment: "Close SSH window confirmation button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct TerminalWindowRegistration {
    let profile: ServerProfile
    let sessionPassword: String?
    let detachSession: (TerminalPane.ID, TerminalSession.ID) -> TerminalSession?
    let insertSession: (TerminalSession, TerminalPane.ID, TerminalSession.ID?) -> Void
    let showDropError: (String) -> Void
    let updateSessionRunning: (TerminalSession.ID, Bool) -> Bool
    let scheduleNormalExitClose: (TerminalSession.ID) -> Bool
    let handleUnexpectedExit: (TerminalSession.ID, Int32) -> Bool
    let updateSessionTitle: (TerminalSession.ID, String) -> Bool
    let hasRunningSessions: () -> Bool
    let closeAllSessions: () -> Void
}

private final class TerminalWindowDelegate: NSObject, NSWindowDelegate {
    let windowID: UUID
    var closeObserver: NSObjectProtocol?

    init(windowID: UUID) {
        self.windowID = windowID
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        SSHSessionWindowManager.shouldCloseWindow(id: windowID)
    }
}

struct ConnectionWindowView: View {
    let windowID: UUID
    let profile: ServerProfile
    let sessionPassword: String?
    @AppStorage("defaultTextEditor") private var defaultTextEditor = AppPreferenceDefaults.textEditor
    @AppStorage("customTextEditor") private var customTextEditor = AppPreferenceDefaults.customTextEditor
    @AppStorage("autoCloseTerminalTabOnNormalExit") private var autoCloseTerminalTabOnNormalExit = AppPreferenceDefaults.autoCloseTerminalTabOnNormalExit
    @StateObject private var profileStore = ProfileStore()
    @State private var isExplorerVisible = true
    @AppStorage("fileExplorerWidth") private var explorerWidth = 240.0
    @State private var resizingExplorerWidth: CGFloat?
    @State private var terminalLayout: TerminalLayout
    @State private var activePaneID: TerminalPane.ID?
    @State private var dropErrorMessage: String?

    fileprivate init(windowID: UUID, profile: ServerProfile, sessionPassword: String?, initialSession: TerminalSession? = nil) {
        self.windowID = windowID
        self.profile = profile
        self.sessionPassword = sessionPassword
        _terminalLayout = State(initialValue: TerminalLayout(initialSession: initialSession))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = ExplorerWidth.clamped(resizingExplorerWidth ?? explorerWidth, availableWidth: geometry.size.width)
            HStack(spacing: 0) {
                if !profile.disableExplorer {
                    RemoteFolderBrowser(
                        profile: profile,
                        availableProfiles: profileStore.profiles,
                        sessionPassword: sessionPassword,
                        collapseAction: { isExplorerVisible = false },
                        editAction: { item in openRemoteItemInTerminal(item) }
                    )
                    .frame(width: width)
                    .frame(width: isExplorerVisible ? width : 0, alignment: .leading)
                    .clipped()
                    .opacity(isExplorerVisible ? 1 : 0)
                    .allowsHitTesting(isExplorerVisible)
                    .accessibilityHidden(!isExplorerVisible)

                    if isExplorerVisible {
                        ExplorerResizeDivider(width: width) { proposed in
                            resizingExplorerWidth = ExplorerWidth.clamped(proposed, availableWidth: geometry.size.width)
                        } onEnd: { proposed in
                            explorerWidth = ExplorerWidth.clamped(proposed, availableWidth: geometry.size.width)
                            resizingExplorerWidth = nil
                        }
                        .frame(width: ExplorerWidth.divider)
                    } else {
                        VStack {
                            Button { isExplorerVisible = true } label: { Image(systemName: "sidebar.leading") }
                                .buttonStyle(.borderless)
                                .help("Show Files")
                            Spacer()
                        }
                        .padding(.top, 8)
                        .frame(width: 32)
                        .background(Color(nsColor: .controlBackgroundColor))
                        Divider()
                    }
                }

                TerminalLayoutView(
                    windowID: windowID,
                    profile: profile,
                    sessionPassword: sessionPassword,
                    layout: terminalLayout,
                    activePaneID: activePaneID,
                    dropErrorMessage: dropErrorMessage,
                    confirmReconnect: confirmReconnect,
                    actions: TerminalLayoutActions(
                        activatePane: { activePaneID = $0 },
                        addSession: addSession,
                        closeSession: closeSession,
                        selectSession: selectSession,
                        splitPane: splitPane,
                        moveSession: moveSession,
                        detachSession: detachSession,
                        insertSession: insertSession,
                        updateSessionRunning: updateSessionRunning,
                        scheduleNormalExitClose: scheduleNormalExitClose,
                        reconnectSession: reconnectSession,
                        updateSessionTitle: updateSessionTitle,
                        showDropError: showDropError
                    )
                )
                .frame(minWidth: 620)
            }
        }
        .frame(minWidth: 920, minHeight: 560)
        .onAppear {
            if activePaneID == nil {
                activePaneID = terminalLayout.firstPaneID
            }
            SSHSessionWindowManager.registerWindow(
                id: windowID,
                profile: profile,
                sessionPassword: sessionPassword,
                detachSession: detachSession,
                insertSession: insertSession,
                showDropError: showDropError,
                updateSessionRunning: updateSessionRunning,
                scheduleNormalExitClose: scheduleNormalExitClose,
                handleUnexpectedExit: handleUnexpectedExit,
                updateSessionTitle: updateSessionTitle,
                hasRunningSessions: hasRunningSessions,
                closeAllSessions: closeAllSessions
            )
        }
        .onDisappear {
            SSHSessionWindowManager.unregisterWindow(id: windowID)
            terminalLayout.terminateAll()
        }
    }

    private func confirmReconnect(status: Int32) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("SSH connection closed", comment: "SSH reconnect alert title")
        alert.informativeText = String(
            format: NSLocalizedString("The session ended unexpectedly with status %d.", comment: "SSH reconnect alert message"),
            status
        )
        alert.addButton(withTitle: NSLocalizedString("Reconnect", comment: "Reconnect button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmCloseSession(title: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Close this terminal tab?", comment: "Terminal tab close confirmation title")
        alert.informativeText = String(
            format: NSLocalizedString("The terminal tab \"%@\" is still running. It will receive an exit command and disconnect.", comment: "Terminal tab close confirmation message"),
            title
        )
        alert.addButton(withTitle: NSLocalizedString("Close Tab", comment: "Close terminal tab confirmation button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func addSession(to paneID: TerminalPane.ID) {
        terminalLayout.addSession(to: paneID)
        activePaneID = paneID
    }

    private func openRemoteItemInTerminal(_ item: RemoteFileItem) {
        if item.isBrowsableDirectory {
            openRemoteFolderInTerminal(item)
            return
        }

        openRemoteFileInEditor(item)
    }

    private func openRemoteFileInEditor(_ item: RemoteFileItem) {
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

    private func openRemoteFolderInTerminal(_ item: RemoteFileItem) {
        let paneID = terminalLayout.validPaneID(preferred: activePaneID)
        terminalLayout.addSession(
            to: paneID,
            title: item.name,
            startupCommand: folderStartupCommand(path: item.path)
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

    private func folderStartupCommand(path: String) -> String {
        let quotedPath = SSHCommandBuilder.shellQuotedArgument(path)
        return "cd \(quotedPath); exec \"${SHELL:-/bin/sh}\""
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
        if let session = terminalLayout.session(sessionID, in: paneID),
           session.isRunning,
           !confirmCloseSession(title: session.title) {
            return
        }

        terminalLayout.closeSession(sessionID, in: paneID)
        activePaneID = terminalLayout.validPaneID(preferred: paneID)
    }

    private func scheduleNormalExitClose(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        guard autoCloseTerminalTabOnNormalExit else {
            return
        }

        guard terminalLayout.containsSession(sessionID, in: paneID) else {
            return
        }

        terminalLayout.removeExitedSession(sessionID, in: paneID)
        activePaneID = terminalLayout.validPaneID(preferred: paneID)
    }

    @discardableResult
    private func scheduleNormalExitClose(_ sessionID: TerminalSession.ID) -> Bool {
        guard let paneID = terminalLayout.paneID(containing: sessionID) else {
            return false
        }

        scheduleNormalExitClose(sessionID, in: paneID)
        return true
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

    private func detachSession(_ paneID: TerminalPane.ID, _ sessionID: TerminalSession.ID) -> TerminalSession? {
        let session = terminalLayout.detachSession(sessionID, from: paneID)
        activePaneID = terminalLayout.validPaneID(preferred: paneID)
        return session
    }

    private func insertSession(_ session: TerminalSession, into paneID: TerminalPane.ID, before targetSessionID: TerminalSession.ID?) {
        terminalLayout.insertSession(session, into: paneID, before: targetSessionID)
        activePaneID = paneID
    }

    private func updateSessionRunning(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID, isRunning: Bool) {
        terminalLayout.updateSessionRunning(sessionID, in: paneID, isRunning: isRunning)
    }

    @discardableResult
    private func updateSessionRunning(_ sessionID: TerminalSession.ID, isRunning: Bool) -> Bool {
        guard let paneID = terminalLayout.paneID(containing: sessionID) else {
            return false
        }

        terminalLayout.updateSessionRunning(sessionID, in: paneID, isRunning: isRunning)
        return true
    }

    private func reconnectSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        terminalLayout.reconnectSession(sessionID, in: paneID)
        activePaneID = paneID
    }

    @discardableResult
    private func handleUnexpectedExit(_ sessionID: TerminalSession.ID, status: Int32) -> Bool {
        guard let paneID = terminalLayout.paneID(containing: sessionID) else {
            return false
        }

        if confirmReconnect(status: status) {
            terminalLayout.reconnectSession(sessionID, in: paneID)
            activePaneID = paneID
        }
        return true
    }

    private func updateSessionTitle(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID, title: String) {
        terminalLayout.updateSessionTitle(sessionID, in: paneID, title: displayTitle(from: title))
    }

    @discardableResult
    private func updateSessionTitle(_ sessionID: TerminalSession.ID, title: String) -> Bool {
        guard let paneID = terminalLayout.paneID(containing: sessionID) else {
            return false
        }

        terminalLayout.updateSessionTitle(sessionID, in: paneID, title: displayTitle(from: title))
        return true
    }

    private func showDropError(_ message: String) {
        dropErrorMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if dropErrorMessage == message {
                dropErrorMessage = nil
            }
        }
    }

    private func closeAllSessions() {
        terminalLayout.terminateAll()
    }

    private func hasRunningSessions() -> Bool {
        terminalLayout.hasRunningSessions
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
    var isRunning = false
    let runtime = TerminalSessionRuntime()

    static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.terminalID == rhs.terminalID
            && lhs.startupCommand == rhs.startupCommand
            && lhs.isRunning == rhs.isRunning
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
    var primary: TerminalPane
    var secondary: TerminalPane?
    var splitAxis: TerminalSplitAxis?

    init(initialSession: TerminalSession? = nil) {
        if let initialSession {
            primary = TerminalPane(sessions: [initialSession])
        } else {
            primary = TerminalPane()
        }
    }

    var firstPaneID: TerminalPane.ID? {
        primary.id
    }

    func paneID(containing sessionID: TerminalSession.ID) -> TerminalPane.ID? {
        if primary.sessions.contains(where: { $0.id == sessionID }) {
            return primary.id
        }

        if let secondary, secondary.sessions.contains(where: { $0.id == sessionID }) {
            return secondary.id
        }

        return nil
    }

    var hasRunningSessions: Bool {
        primary.sessions.contains { $0.isRunning }
            || secondary?.sessions.contains { $0.isRunning } == true
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
            pane.sessions[index].runtime.closeGracefully()
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

    mutating func removeExitedSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
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

    func containsSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) -> Bool {
        if primary.id == paneID {
            return primary.sessions.contains { $0.id == sessionID }
        }

        if let secondary, secondary.id == paneID {
            return secondary.sessions.contains { $0.id == sessionID }
        }

        return false
    }

    func session(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) -> TerminalSession? {
        if primary.id == paneID {
            return primary.sessions.first { $0.id == sessionID }
        }

        if let secondary, secondary.id == paneID {
            return secondary.sessions.first { $0.id == sessionID }
        }

        return nil
    }

    mutating func selectSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        updatePane(paneID) { pane in
            guard pane.sessions.contains(where: { $0.id == sessionID }) else {
                return
            }
            pane.selectedSessionID = sessionID
        }
    }

    mutating func updateSessionRunning(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID, isRunning: Bool) {
        updateSession(sessionID, in: paneID) { session in
            session.isRunning = isRunning
        }
    }

    mutating func reconnectSession(_ sessionID: TerminalSession.ID, in paneID: TerminalPane.ID) {
        updateSession(sessionID, in: paneID) { session in
            session.runtime.reset()
            session.terminalID = UUID()
            session.isRunning = false
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

    mutating func detachSession(_ sessionID: TerminalSession.ID, from paneID: TerminalPane.ID) -> TerminalSession? {
        let session = removeSession(sessionID, from: paneID)
        collapseEmptySplitPane()
        return session
    }

    mutating func insertSession(_ session: TerminalSession, into paneID: TerminalPane.ID, before targetSessionID: TerminalSession.ID?) {
        updatePane(paneID) { pane in
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
        primary.sessions.forEach { $0.runtime.closeGracefully() }
        secondary?.sessions.forEach { $0.runtime.closeGracefully() }
    }
}

private struct TerminalLayoutActions {
    let activatePane: (TerminalPane.ID) -> Void
    let addSession: (TerminalPane.ID) -> Void
    let closeSession: (TerminalSession.ID, TerminalPane.ID) -> Void
    let selectSession: (TerminalSession.ID, TerminalPane.ID) -> Void
    let splitPane: (TerminalPane.ID, TerminalSplitAxis) -> Void
    let moveSession: (TerminalSession.ID, TerminalPane.ID, TerminalPane.ID, TerminalSession.ID?) -> Void
    let detachSession: (TerminalPane.ID, TerminalSession.ID) -> TerminalSession?
    let insertSession: (TerminalSession, TerminalPane.ID, TerminalSession.ID?) -> Void
    let updateSessionRunning: (TerminalSession.ID, TerminalPane.ID, Bool) -> Void
    let scheduleNormalExitClose: (TerminalSession.ID, TerminalPane.ID) -> Void
    let reconnectSession: (TerminalSession.ID, TerminalPane.ID) -> Void
    let updateSessionTitle: (TerminalSession.ID, TerminalPane.ID, String) -> Void
    let showDropError: (String) -> Void
}

private struct TerminalDragContext {
    let windowID: UUID
    let paneID: TerminalPane.ID
    let sessionID: TerminalSession.ID
}

private enum TerminalTabDragStore {
    static let acceptedTypes: [UTType] = [AppDragTypes.terminalTab]
    @MainActor static var context: TerminalDragContext?
    @MainActor private static var token: UUID?

    @MainActor
    static func begin(_ dragContext: TerminalDragContext) -> UUID {
        context = dragContext
        let token = UUID()
        self.token = token
        return token
    }

    @MainActor
    static func clear() {
        context = nil
        token = nil
    }

    @MainActor
    static func context(for dragToken: UUID) -> TerminalDragContext? {
        guard token == dragToken else {
            return nil
        }

        return context
    }

    @MainActor
    static func finishDrag(token dragToken: UUID, at screenPoint: NSPoint) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let context = context(for: dragToken) else {
                return
            }

            clear()
            guard !SSHSessionWindowManager.isPointInsideSessionWindow(screenPoint) else {
                return
            }

            SSHSessionWindowManager.detachTerminalSessionToNewWindow(context, at: screenPoint)
        }
    }

}

private struct TerminalTabDragSource: NSViewRepresentable {
    let context: TerminalDragContext
    let onClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(context: context, onClick: onClick)
    }

    func makeNSView(context: Context) -> TerminalTabDragSourceView {
        let view = TerminalTabDragSourceView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TerminalTabDragSourceView, context: Context) {
        context.coordinator.context = self.context
        context.coordinator.onClick = onClick
        nsView.coordinator = context.coordinator
    }

    final class Coordinator: NSObject, NSDraggingSource {
        var context: TerminalDragContext
        var onClick: () -> Void
        private var activeToken: UUID?

        init(context: TerminalDragContext, onClick: @escaping () -> Void) {
            self.context = context
            self.onClick = onClick
        }

        func beginDrag(from view: NSView, with event: NSEvent) {
            let token = TerminalTabDragStore.begin(context)
            activeToken = token

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(token.uuidString, forType: .string)

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            draggingItem.setDraggingFrame(view.bounds, contents: dragPreviewImage())
            view.beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .move
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            true
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let activeToken else {
                return
            }

            self.activeToken = nil
            TerminalTabDragStore.finishDrag(token: activeToken, at: screenPoint)
        }

        private func dragPreviewImage() -> NSImage {
            let size = NSSize(width: 12, height: 30)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 4, width: 2, height: 22), xRadius: 1, yRadius: 1).fill()
            image.unlockFocus()
            return image
        }
    }
}

private final class TerminalTabDragSourceView: NSView {
    weak var coordinator: TerminalTabDragSource.Coordinator?
    private var mouseDownEvent: NSEvent?
    private var mouseDownLocation: NSPoint?
    private var didStartDrag = false

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        mouseDownLocation = event.locationInWindow
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag,
              let mouseDownEvent,
              let mouseDownLocation else {
            return
        }

        let distance = hypot(event.locationInWindow.x - mouseDownLocation.x, event.locationInWindow.y - mouseDownLocation.y)
        guard distance >= 4 else {
            return
        }

        didStartDrag = true
        coordinator?.beginDrag(from: self, with: mouseDownEvent)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            mouseDownLocation = nil
            didStartDrag = false
        }

        if !didStartDrag {
            coordinator?.onClick()
        }
    }
}

private struct TerminalLayoutView: View {
    let windowID: UUID
    let profile: ServerProfile
    let sessionPassword: String?
    let layout: TerminalLayout
    let activePaneID: TerminalPane.ID?
    let dropErrorMessage: String?
    let confirmReconnect: (Int32) -> Bool
    let actions: TerminalLayoutActions

    var body: some View {
        ZStack(alignment: .top) {
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

            if let dropErrorMessage {
                Text(dropErrorMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .systemRed), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 42)
                    .transition(.opacity)
            }
        }
    }

    private func paneView(_ pane: TerminalPane) -> some View {
        TerminalPaneView(
            windowID: windowID,
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
    let windowID: UUID
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
                                HStack(spacing: 6) {
                                    Image(systemName: "terminal")
                                        .font(.caption)
                                    Text(session.title)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                                .overlay(
                                    TerminalTabDragSource(
                                        context: TerminalDragContext(
                                            windowID: windowID,
                                            paneID: pane.id,
                                            sessionID: session.id
                                        ),
                                        onClick: {
                                            actions.selectSession(session.id, pane.id)
                                        }
                                    )
                                )

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
                            onRunningChanged: { isRunning in
                                SSHSessionWindowManager.updateTerminalSessionRunning(session.id, isRunning: isRunning)
                            },
                            onNormalExit: {
                                SSHSessionWindowManager.scheduleNormalExitClose(session.id)
                            },
                            onUnexpectedExit: { status in
                                SSHSessionWindowManager.handleUnexpectedExit(session.id, status: status)
                            },
                            onTitleChanged: { title in
                                SSHSessionWindowManager.updateTerminalSessionTitle(session.id, title: title)
                            },
                            onFocus: {
                                actions.activatePane(pane.id)
                            }
                        )
                        .id(session.terminalID)
                        .opacity(session.id == pane.selectedSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == pane.selectedSessionID)
                        .onDrop(of: [.item], isTargeted: nil) { providers in
                            handleRemotePathDrop(providers: providers, into: session.runtime)
                        }
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

    private func handleRemotePathDrop(providers: [NSItemProvider], into runtime: TerminalSessionRuntime) -> Bool {
        let hasFileURLProvider = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !hasFileURLProvider,
              let activeDrag = AppDragRegistry.activeRemoteFilePayload else {
            return false
        }

        AppDragRegistry.endRemoteFileDrag(activeDrag.token)

        guard activeDrag.payload.profile.id == profile.id else {
            actions.showDropError(NSLocalizedString("Cannot drop files from a different server into this terminal.", comment: "terminal remote path cross-server drop error"))
            return true
        }

        let text = activeDrag.payload.items
            .map { SSHCommandBuilder.shellQuotedArgument($0.path) }
            .joined(separator: " ") + " "
        runtime.insertText(text)
        return true
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
        if context.windowID == windowID {
            actions.moveSession(context.sessionID, context.paneID, pane.id, targetSessionID)
        } else {
            _ = SSHSessionWindowManager.moveTerminalSession(context, to: windowID, targetPaneID: pane.id, before: targetSessionID)
        }
        return true
    }
}
