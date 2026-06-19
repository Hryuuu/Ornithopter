//
//  TerminalTextView.swift
//  Ornithopter
//

import AppKit
import SwiftUI

#if canImport(SwiftTerm)
import SwiftTerm

struct TerminalTextView: NSViewRepresentable {
    let profile: ServerProfile
    let sessionPassword: String?
    let onRunningChanged: (Bool) -> Void
    let onUnexpectedExit: (Int32) -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = LocalProcessTerminalView(frame: .zero)
        terminalView.processDelegate = context.coordinator
        terminalView.nativeBackgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        terminalView.caretColor = NSColor(calibratedRed: 0.65, green: 0.95, blue: 0.62, alpha: 1)
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.backspaceSendsControlH = false
        terminalView.getTerminal().registerOscHandler(code: 3008) { _ in }

        context.coordinator.startIfNeeded(terminalView)
        return terminalView
    }

    func updateNSView(_ terminalView: LocalProcessTerminalView, context: Context) {
        context.coordinator.profile = profile
        context.coordinator.sessionPassword = sessionPassword
        context.coordinator.onRunningChanged = onRunningChanged
        context.coordinator.onUnexpectedExit = onUnexpectedExit

        if terminalView.window?.firstResponder !== terminalView {
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    static func dismantleNSView(_ terminalView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.isClosing = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            profile: profile,
            sessionPassword: sessionPassword,
            onRunningChanged: onRunningChanged,
            onUnexpectedExit: onUnexpectedExit
        )
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var profile: ServerProfile
        var sessionPassword: String?
        var onRunningChanged: (Bool) -> Void
        var onUnexpectedExit: (Int32) -> Void
        var didStart = false
        var isClosing = false

        init(
            profile: ServerProfile,
            sessionPassword: String?,
            onRunningChanged: @escaping (Bool) -> Void,
            onUnexpectedExit: @escaping (Int32) -> Void
        ) {
            self.profile = profile
            self.sessionPassword = sessionPassword
            self.onRunningChanged = onRunningChanged
            self.onUnexpectedExit = onUnexpectedExit
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

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

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
    let onRunningChanged: (Bool) -> Void
    let onUnexpectedExit: (Int32) -> Void

    var body: some View {
        ContentUnavailableView {
            Label("SwiftTerm Not Linked", systemImage: "terminal")
        } description: {
            Text("Open the project in Xcode and let Swift Package Manager resolve SwiftTerm.")
        }
    }
}

#endif
