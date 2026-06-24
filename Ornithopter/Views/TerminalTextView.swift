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
    private var isClosed = false

    func terminate() {
#if canImport(SwiftTerm)
        guard !isClosed else {
            return
        }
        isClosed = true
        coordinator?.isClosing = true
        terminalView?.terminate()
        terminalView?.removeFromSuperview()
        terminalView = nil
        coordinator = nil
#endif
    }

    func closeGracefully() {
#if canImport(SwiftTerm)
        guard !isClosed else {
            return
        }
        isClosed = true
        coordinator?.isClosing = true
        terminalView?.send(Array("exit\n".utf8))

        let viewToTerminate = terminalView
        let viewToRemove = terminalView
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            viewToTerminate?.terminate()
            viewToRemove?.removeFromSuperview()
        }

        terminalView = nil
        coordinator = nil
#endif
    }

    func reset() {
        terminate()
        isClosed = false
    }

    func insertText(_ text: String) {
#if canImport(SwiftTerm)
        guard let terminalView else {
            return
        }

        terminalView.send(Array(text.utf8))
#endif
    }
}

#if canImport(SwiftTerm)

final class OrnithopterTerminalView: LocalProcessTerminalView {
    private var isComposingMarkedText = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        isComposingMarkedText = Self.plainText(from: string)?.isEmpty == false
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = Self.plainText(from: string),
              shouldSendIMECommitAsText(text) else {
            isComposingMarkedText = false
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        super.unmarkText()
        isComposingMarkedText = false
        send(txt: text)
    }

    override func unmarkText() {
        isComposingMarkedText = false
        super.unmarkText()
    }

    private func shouldSendIMECommitAsText(_ text: String) -> Bool {
        isComposingMarkedText && text.unicodeScalars.contains(where: Self.isHangulScalar)
    }

    nonisolated private static func plainText(from value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let attributed as NSAttributedString:
            return attributed.string
        default:
            return nil
        }
    }

    nonisolated private static func isHangulScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x3130...0x318F,   // Hangul Compatibility Jamo
             0xA960...0xA97F,   // Hangul Jamo Extended-A
             0xAC00...0xD7A3,   // Hangul Syllables
             0xD7B0...0xD7FF:   // Hangul Jamo Extended-B
            return true
        default:
            return false
        }
    }
}

struct TerminalTextView: NSViewRepresentable {
    let profile: ServerProfile
    let sessionPassword: String?
    let runtime: TerminalSessionRuntime
    let isActive: Bool
    let startupCommand: String?
    let onRunningChanged: (Bool) -> Void
    let onNormalExit: () -> Void
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
            startupCommand: startupCommand,
            onRunningChanged: onRunningChanged,
            onNormalExit: onNormalExit,
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
        coordinator.startupCommand = startupCommand
        coordinator.onRunningChanged = onRunningChanged
        coordinator.onNormalExit = onNormalExit
        coordinator.onUnexpectedExit = onUnexpectedExit
        coordinator.onTitleChanged = onTitleChanged

        runtime.terminalView = terminalView
        terminalView.processDelegate = coordinator
        terminalView.needsDisplay = true
        coordinator.startIfNeeded(terminalView)
    }

    private func makeTerminalView(coordinator: Coordinator) -> LocalProcessTerminalView {
        let terminalView = OrnithopterTerminalView(frame: .zero)
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
        var startupCommand: String?
        var onRunningChanged: (Bool) -> Void
        var onNormalExit: () -> Void
        var onUnexpectedExit: (Int32) -> Void
        var onTitleChanged: (String) -> Void
        var didStart = false
        var isClosing = false
        private weak var terminalView: LocalProcessTerminalView?
        private var keyMonitor: Any?

        init(
            profile: ServerProfile,
            sessionPassword: String?,
            startupCommand: String?,
            onRunningChanged: @escaping (Bool) -> Void,
            onNormalExit: @escaping () -> Void,
            onUnexpectedExit: @escaping (Int32) -> Void,
            onTitleChanged: @escaping (String) -> Void
        ) {
            self.profile = profile
            self.sessionPassword = sessionPassword
            self.startupCommand = startupCommand
            self.onRunningChanged = onRunningChanged
            self.onNormalExit = onNormalExit
            self.onUnexpectedExit = onUnexpectedExit
            self.onTitleChanged = onTitleChanged
        }

        func startIfNeeded(_ terminalView: LocalProcessTerminalView) {
            self.terminalView = terminalView
            installKeyMonitorIfNeeded()

            guard !didStart else {
                return
            }

            didStart = true
            notifyRunningChanged(true)

            terminalView.startProcess(
                executable: "/usr/bin/ssh",
                args: SSHCommandBuilder.sshArguments(for: profile, startupCommand: startupCommand),
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
            if status == 0 {
                notifyNormalExit()
            } else {
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

        private func notifyNormalExit() {
            DispatchQueue.main.async { [weak self] in
                self?.onNormalExit()
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

        private func installKeyMonitorIfNeeded() {
            guard keyMonitor == nil else {
                return
            }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.sendControlShortcutIfNeeded(event) else {
                    return event
                }

                return nil
            }
        }

        private func sendControlShortcutIfNeeded(_ event: NSEvent) -> Bool {
            guard let terminalView,
                  terminalView.window?.firstResponder === terminalView else {
                return false
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control),
                  !flags.contains(.command),
                  !flags.contains(.option),
                  let byte = controlByte(for: event) else {
                return false
            }

            terminalView.send([byte])
            return true
        }

        private func controlByte(for event: NSEvent) -> UInt8? {
            switch event.keyCode {
            case 0: return 0x01 // A
            case 11: return 0x02 // B
            case 8: return 0x03 // C
            case 2: return 0x04 // D
            case 14: return 0x05 // E
            case 3: return 0x06 // F
            case 5: return 0x07 // G
            case 4: return 0x08 // H
            case 34: return 0x09 // I
            case 38: return 0x0a // J
            case 40: return 0x0b // K
            case 37: return 0x0c // L
            case 46: return 0x0d // M
            case 45: return 0x0e // N
            case 31: return 0x0f // O
            case 35: return 0x10 // P
            case 12: return 0x11 // Q
            case 15: return 0x12 // R
            case 1: return 0x13 // S
            case 17: return 0x14 // T
            case 32: return 0x15 // U
            case 9: return 0x16 // V
            case 13: return 0x17 // W
            case 7: return 0x18 // X
            case 16: return 0x19 // Y
            case 6: return 0x1a // Z
            case 49: return 0x00 // Space
            case 33: return 0x1b // [
            case 42: return 0x1c // \
            case 30: return 0x1d // ]
            case 27: return 0x1f // -
            default: return nil
            }
        }

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }
    }
}

#else

struct TerminalTextView: View {
    let profile: ServerProfile
    let sessionPassword: String?
    let runtime: TerminalSessionRuntime
    let isActive: Bool
    let startupCommand: String?
    let onRunningChanged: (Bool) -> Void
    let onNormalExit: () -> Void
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
