//
//  TerminalTextView.swift
//  Ornithopter
//

import AppKit
import SwiftUI

#if canImport(SwiftTerm)
import SwiftTerm
#endif

final class TerminalSessionRuntime {
#if canImport(SwiftTerm)
    fileprivate var terminalView: LocalProcessTerminalView?
    fileprivate var coordinator: TerminalTextView.Coordinator?
#endif

    func terminate() {
#if canImport(SwiftTerm)
        coordinator?.isClosing = true
        terminalView?.terminate()
        terminalView?.removeFromSuperview()
        terminalView = nil
        coordinator = nil
#endif
    }

    func reset() {
        terminate()
    }
}

#if canImport(SwiftTerm)

struct TerminalTextView: NSViewRepresentable {
    let profile: ServerProfile
    let sessionPassword: String?
    let runtime: TerminalSessionRuntime
    let isActive: Bool
    let onRunningChanged: (Bool) -> Void
    let onUnexpectedExit: (Int32) -> Void
    let onTitleChanged: (String) -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        attachTerminal(context: context)
    }

    func updateNSView(_ terminalView: LocalProcessTerminalView, context: Context) {
        updateTerminal(terminalView, context: context)

        if isActive, terminalView.window?.firstResponder !== terminalView {
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    static func dismantleNSView(_ terminalView: LocalProcessTerminalView, coordinator: Coordinator) {
        // The terminal view is owned by TerminalSessionRuntime. SwiftUI can dismantle
        // this wrapper during tab moves or split changes; do not tear down the live
        // terminal unless the session itself is closed.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            profile: profile,
            sessionPassword: sessionPassword,
            onRunningChanged: onRunningChanged,
            onUnexpectedExit: onUnexpectedExit,
            onTitleChanged: onTitleChanged
        )
    }

    @discardableResult
    private func attachTerminal(context: Context) -> LocalProcessTerminalView {
        let terminalView = runtime.terminalView ?? makeTerminalView(coordinator: runtime.coordinator ?? context.coordinator)
        terminalView.removeFromSuperview()
        runtime.terminalView = terminalView
        updateTerminal(terminalView, context: context)
        return terminalView
    }

    private func updateTerminal(_ terminalView: LocalProcessTerminalView, context: Context) {
        let coordinator = runtime.coordinator ?? context.coordinator
        runtime.coordinator = coordinator
        coordinator.profile = profile
        coordinator.sessionPassword = sessionPassword
        coordinator.onRunningChanged = onRunningChanged
        coordinator.onUnexpectedExit = onUnexpectedExit
        coordinator.onTitleChanged = onTitleChanged

        runtime.terminalView = terminalView
        terminalView.processDelegate = coordinator
        terminalView.needsDisplay = true
        coordinator.startIfNeeded(terminalView)
    }

    private func makeTerminalView(coordinator: Coordinator) -> LocalProcessTerminalView {
        let terminalView = LocalProcessTerminalView(frame: .zero)
        terminalView.processDelegate = coordinator
        terminalView.nativeBackgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        terminalView.caretColor = NSColor(calibratedRed: 0.65, green: 0.95, blue: 0.62, alpha: 1)
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.backspaceSendsControlH = false
        terminalView.getTerminal().registerOscHandler(code: 3008) { _ in }
        return terminalView
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var profile: ServerProfile
        var sessionPassword: String?
        var onRunningChanged: (Bool) -> Void
        var onUnexpectedExit: (Int32) -> Void
        var onTitleChanged: (String) -> Void
        var didStart = false
        var isClosing = false

        init(
            profile: ServerProfile,
            sessionPassword: String?,
            onRunningChanged: @escaping (Bool) -> Void,
            onUnexpectedExit: @escaping (Int32) -> Void,
            onTitleChanged: @escaping (String) -> Void
        ) {
            self.profile = profile
            self.sessionPassword = sessionPassword
            self.onRunningChanged = onRunningChanged
            self.onUnexpectedExit = onUnexpectedExit
            self.onTitleChanged = onTitleChanged
        }

        func startIfNeeded(_ terminalView: LocalProcessTerminalView) {
            guard !didStart else {
                return
            }

            didStart = true
            notifyRunningChanged(true)

            terminalView.startProcess(
                executable: "/usr/bin/ssh",
                args: SSHCommandBuilder.sshArguments(for: profile),
                environment: terminalEnvironment(),
                execName: "ssh"
            )
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else {
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.onTitleChanged(String(cleanTitle.prefix(40)))
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            notifyRunningChanged(false)

            guard !isClosing else {
                return
            }

            let status = exitCode ?? -1
            if status != 0 {
                notifyUnexpectedExit(status)
            }
        }

        private func notifyRunningChanged(_ running: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.onRunningChanged(running)
            }
        }

        private func notifyUnexpectedExit(_ status: Int32) {
            DispatchQueue.main.async { [weak self] in
                self?.onUnexpectedExit(status)
            }
        }

        private func terminalEnvironment() -> [String] {
            ProcessInfo.processInfo.environment
                .merging([
                    "TERM": "xterm-256color",
                    "LANG": "en_US.UTF-8",
                    "LC_CTYPE": "en_US.UTF-8"
                ]) { _, new in new }
                .merging(SSHAskPass.environment(password: sessionPassword)) { _, new in new }
                .map { "\($0.key)=\($0.value)" }
        }
    }
}

#else

struct TerminalTextView: View {
    let profile: ServerProfile
    let sessionPassword: String?
    let runtime: TerminalSessionRuntime
    let isActive: Bool
    let onRunningChanged: (Bool) -> Void
    let onUnexpectedExit: (Int32) -> Void
    let onTitleChanged: (String) -> Void

    var body: some View {
        ContentUnavailableView {
            Label("SwiftTerm Not Linked", systemImage: "terminal")
        } description: {
            Text("Open the project in Xcode and let Swift Package Manager resolve SwiftTerm.")
        }
    }
}

#endif
