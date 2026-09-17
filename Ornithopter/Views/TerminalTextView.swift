//
//  TerminalTextView.swift
//  Ornithopter
//

import AppKit
import Darwin
import OSLog
import SwiftUI

#if canImport(SwiftTerm)
import SwiftTerm
#endif

final class TerminalSessionRuntime {
    private static let logger = Logger(subsystem: "kucc.co.kr.Ornithopter", category: "TerminalSession")
    private var generation = UUID()
#if canImport(SwiftTerm)
    fileprivate var terminalView: LocalProcessTerminalView?
    fileprivate var coordinator: TerminalTextView.Coordinator?
    fileprivate let processDelegate = TerminalRuntimeProcessDelegate()
#endif
    private var isClosed = false
    private var isClosing = false
    private var didStart = false
    private var didReceiveTermination = false
    private var nonRunningPollCount = 0
    private var terminationPoller: DispatchSourceTimer?
    private var askPassSession: SSHAskPassSession?
    private var onRunningChanged: ((Bool) -> Void)?
    private var onNormalExit: (() -> Void)?
    private var onUnexpectedExit: ((Int32) -> Void)?
    private var onTitleChanged: ((String) -> Void)?

    init() {
    #if canImport(SwiftTerm)
        processDelegate.runtime = self
    #endif
    }

    deinit {
    #if canImport(SwiftTerm)
        stopTerminationPoller()
        stopAskPassSession()
    #endif
    }

    func prepareForAttachment() {
    #if canImport(SwiftTerm)
        isClosed = false
        isClosing = false
    #endif
    }

    func terminate() {
#if canImport(SwiftTerm)
        guard !isClosed else {
            return
        }
        isClosed = true
        isClosing = true
        generation = UUID()
        coordinator?.stopMonitoring()
        stopTerminationPoller()
        stopAskPassSession()
        (terminalView as? OrnithopterTerminalView)?.onFocus = nil
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
        isClosing = true
        generation = UUID()
        coordinator?.stopMonitoring()
        stopTerminationPoller()
        stopAskPassSession()
        (terminalView as? OrnithopterTerminalView)?.onFocus = nil
        terminalView?.send(Array("exit\n".utf8))

        let viewToTerminate = terminalView
        let viewToRemove = terminalView
        // Normal window/app closes give the remote shell time to process exit.
        // Crashes, force quits, and power loss can still leave cleanup to the OS.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
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
        isClosing = false
        didStart = false
        didReceiveTermination = false
        nonRunningPollCount = 0
    }

    func insertText(_ text: String) {
#if canImport(SwiftTerm)
        guard let terminalView else {
            return
        }

        terminalView.send(Array(text.utf8))
#endif
    }

#if canImport(SwiftTerm)
    fileprivate func configureCallbacks(
        onRunningChanged: @escaping (Bool) -> Void,
        onNormalExit: @escaping () -> Void,
        onUnexpectedExit: @escaping (Int32) -> Void,
        onTitleChanged: @escaping (String) -> Void
    ) {
        self.onRunningChanged = onRunningChanged
        self.onNormalExit = onNormalExit
        self.onUnexpectedExit = onUnexpectedExit
        self.onTitleChanged = onTitleChanged
    }

    fileprivate func startIfNeeded(
        terminalView: LocalProcessTerminalView,
        profile: ServerProfile,
        sessionPassword: String?,
        startupCommand: String?
    ) {
        self.terminalView = terminalView

        guard !didStart else {
            return
        }

        didStart = true
        generation = UUID()
        Self.logger.info("Starting SSH session \(self.generation)")
        didReceiveTermination = false
        nonRunningPollCount = 0
        notifyRunningChanged(true)
        askPassSession = SSHAskPassSession(password: sessionPassword)

        terminalView.startProcess(
            executable: "/usr/bin/ssh",
            args: SSHCommandBuilder.sshArguments(for: profile, startupCommand: startupCommand),
            environment: terminalEnvironment(),
            execName: "ssh"
        )
        startTerminationPoller()
    }

    fileprivate func setTerminalTitle(_ title: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            return
        }

        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, !self.isClosed else { return }
            self.onTitleChanged?(String(cleanTitle.prefix(40)))
        }
    }

    fileprivate func processTerminated(exitCode: Int32?) {
        guard !didReceiveTermination else {
            return
        }

        didReceiveTermination = true
        Self.logger.info("SSH session \(self.generation) terminated, status \(exitCode ?? -1)")
        stopTerminationPoller()
        stopAskPassSession()
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
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, !self.isClosed else { return }
            self.onRunningChanged?(running)
        }
    }

    private func notifyUnexpectedExit(_ status: Int32) {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, !self.isClosed else { return }
            self.onUnexpectedExit?(status)
        }
    }

    private func notifyNormalExit() {
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, !self.isClosed else { return }
            self.onNormalExit?()
        }
    }

    private func terminalEnvironment() -> [String] {
        SSHProcessEnvironment.baseEnvironment()
            .merging(askPassSession?.environment ?? [:]) { _, new in new }
            .map { "\($0.key)=\($0.value)" }
    }

    fileprivate func stopAskPassSession() {
        askPassSession?.stop()
        askPassSession = nil
    }

    private func startTerminationPoller() {
        stopTerminationPoller()

        let poller = DispatchSource.makeTimerSource(queue: .main)
        poller.schedule(deadline: .now() + 0.5, repeating: .milliseconds(500))
        poller.setEventHandler { [weak self] in
            self?.pollForMissedTermination()
        }
        terminationPoller = poller
        poller.resume()
    }

    private func stopTerminationPoller() {
        terminationPoller?.cancel()
        terminationPoller = nil
        nonRunningPollCount = 0
    }

    private func pollForMissedTermination() {
        guard didStart, !isClosed, !didReceiveTermination, let process = terminalView?.process else {
            stopTerminationPoller()
            return
        }

        guard !process.running else {
            nonRunningPollCount = 0
            return
        }

        nonRunningPollCount += 1
        // SwiftTerm owns waitpid. Reaping here races its process monitor and can
        // turn a failed connection into an apparent successful exit.
        if nonRunningPollCount >= 4 {
            processTerminated(exitCode: nil)
        }
    }
#endif
}

#if canImport(SwiftTerm)

private final class TerminalRuntimeProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    weak var runtime: TerminalSessionRuntime?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard runtime?.terminalView === source else { return }
        runtime?.setTerminalTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard runtime?.terminalView === source else { return }
        // The pinned SwiftTerm LocalProcess reports the raw waitpid status.
        let status = exitCode.map { raw in
            raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        }
        runtime?.processTerminated(exitCode: status)
    }
}

final class OrnithopterTerminalView: LocalProcessTerminalView {
    var onFocus: (() -> Void)?
    private var selectedForInput = false
    private var needsSelectionFocus = false

    func updateInputSelection(_ selected: Bool) {
        if selected && !selectedForInput { needsSelectionFocus = true }
        selectedForInput = selected
        if !selected { needsSelectionFocus = false }
        focusSelectionIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if selectedForInput { needsSelectionFocus = true }
        DispatchQueue.main.async { [weak self] in self?.focusSelectionIfNeeded() }
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    private func focusSelectionIfNeeded() {
        guard needsSelectionFocus, selectedForInput, let window else { return }
        // Set this window's responder only on selection/attachment, not on every
        // SwiftUI refresh (which can steal focus from file search or a dialog).
        if window.makeFirstResponder(self) { needsSelectionFocus = false }
    }
    private static let clearScrollbackSequence: [UInt8] = [0x1b, 0x5b, 0x33, 0x4a]
    private static let trackedCommandLengthLimit = 512

    private var isComposingMarkedText = false
    private var trackedCommandText = ""

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        isComposingMarkedText = Self.plainText(from: string)?.isEmpty == false
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainText(from: string)
        guard let text,
              shouldSendIMECommitAsText(text) else {
            isComposingMarkedText = false
            super.insertText(string, replacementRange: replacementRange)
            if let text {
                trackInsertedText(text)
            }
            return
        }

        super.unmarkText()
        isComposingMarkedText = false
        send(txt: text)
        trackInsertedText(text)
    }

    override func unmarkText() {
        isComposingMarkedText = false
        super.unmarkText()
    }

    func trackCommandKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command),
              !flags.contains(.option) else {
            return
        }

        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            let shouldClearScrollback = isTrackedCommandClear()
            trackedCommandText = ""
            if shouldClearScrollback {
                DispatchQueue.main.async { [weak self] in
                    self?.clearLocalScrollback()
                }
            }
        case 51: // Delete/Backspace
            removeLastTrackedCharacter()
        case 53: // Escape
            trackedCommandText = ""
        default:
            break
        }
    }

    private func shouldSendIMECommitAsText(_ text: String) -> Bool {
        isComposingMarkedText && text.unicodeScalars.contains(where: Self.isHangulScalar)
    }

    private func trackInsertedText(_ text: String) {
        for character in text {
            switch character {
            case "\r", "\n":
                submitTrackedCommand(shouldClearScrollback: isTrackedCommandClear())
            case "\u{08}", "\u{7f}":
                removeLastTrackedCharacter()
            default:
                guard !character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    continue
                }

                trackedCommandText.append(character)
                if trackedCommandText.count > Self.trackedCommandLengthLimit {
                    trackedCommandText.removeFirst(trackedCommandText.count - Self.trackedCommandLengthLimit)
                }
            }
        }
    }

    private func submitTrackedCommand(shouldClearScrollback: Bool) {
        trackedCommandText = ""

        if shouldClearScrollback {
            clearLocalScrollback()
        }
    }

    private func isTrackedCommandClear() -> Bool {
        trackedCommandText.trimmingCharacters(in: .whitespaces) == "clear"
    }

    private func removeLastTrackedCharacter() {
        if !trackedCommandText.isEmpty {
            trackedCommandText.removeLast()
        }
    }

    private func clearLocalScrollback() {
        feed(byteArray: Self.clearScrollbackSequence[...])
        changeScrollback(getTerminal().options.scrollback)
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
    private static let scrollbackLineLimit = 20_000

    let profile: ServerProfile
    let sessionPassword: String?
    let runtime: TerminalSessionRuntime
    let isActive: Bool
    let startupCommand: String?
    let onRunningChanged: (Bool) -> Void
    let onNormalExit: () -> Void
    let onUnexpectedExit: (Int32) -> Void
    let onTitleChanged: (String) -> Void
    var onFocus: (() -> Void)? = nil

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        attachTerminal(context: context)
    }

    func updateNSView(_ terminalView: LocalProcessTerminalView, context: Context) {
        updateTerminal(terminalView, context: context)
    }

    static func dismantleNSView(_ terminalView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
        // The terminal view is owned by TerminalSessionRuntime. SwiftUI can dismantle
        // this wrapper during tab moves or split changes; do not tear down the live
        // terminal unless the session itself is closed.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            profile: profile,
            sessionPassword: sessionPassword,
            startupCommand: startupCommand
        )
    }

    @discardableResult
    private func attachTerminal(context: Context) -> LocalProcessTerminalView {
        let existingTerminalView = runtime.terminalView
        if existingTerminalView != nil {
            runtime.prepareForAttachment()
        }

        let terminalView = existingTerminalView ?? makeTerminalView()
        terminalView.removeFromSuperview()
        runtime.terminalView = terminalView
        updateTerminal(terminalView, context: context)
        return terminalView
    }

    private func updateTerminal(_ terminalView: LocalProcessTerminalView, context: Context) {
        let coordinator = context.coordinator
        if runtime.coordinator !== coordinator { runtime.coordinator?.stopMonitoring() }
        coordinator.isActive = isActive
        (terminalView as? OrnithopterTerminalView)?.onFocus = onFocus
        (terminalView as? OrnithopterTerminalView)?.updateInputSelection(isActive)
        runtime.coordinator = coordinator
        coordinator.profile = profile
        coordinator.sessionPassword = sessionPassword
        coordinator.startupCommand = startupCommand

        runtime.terminalView = terminalView
        runtime.configureCallbacks(
            onRunningChanged: onRunningChanged,
            onNormalExit: onNormalExit,
            onUnexpectedExit: onUnexpectedExit,
            onTitleChanged: onTitleChanged
        )
        terminalView.processDelegate = runtime.processDelegate
        applyScrollingConfiguration(to: terminalView)
        terminalView.needsDisplay = true
        coordinator.startIfNeeded(terminalView, runtime: runtime)
    }

    private func makeTerminalView() -> LocalProcessTerminalView {
        let terminalView = OrnithopterTerminalView(frame: .zero)
        terminalView.processDelegate = runtime.processDelegate
        terminalView.nativeBackgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        terminalView.caretColor = NSColor(calibratedRed: 0.65, green: 0.95, blue: 0.62, alpha: 1)
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.backspaceSendsControlH = false
        applyScrollingConfiguration(to: terminalView)
        terminalView.getTerminal().registerOscHandler(code: 3008) { _ in }
        return terminalView
    }

    private func applyScrollingConfiguration(to terminalView: LocalProcessTerminalView) {
        terminalView.scrollerStyle = .legacy

        if terminalView.getTerminal().options.scrollback != Self.scrollbackLineLimit {
            terminalView.changeScrollback(Self.scrollbackLineLimit)
        }
    }

    final class Coordinator: NSObject {
        var profile: ServerProfile
        var sessionPassword: String?
        var startupCommand: String?
        private weak var terminalView: LocalProcessTerminalView?
        private var keyMonitor: Any?
        var isActive = false

        init(
            profile: ServerProfile,
            sessionPassword: String?,
            startupCommand: String?
        ) {
            self.profile = profile
            self.sessionPassword = sessionPassword
            self.startupCommand = startupCommand
        }

        func startIfNeeded(_ terminalView: LocalProcessTerminalView, runtime: TerminalSessionRuntime) {
            self.terminalView = terminalView
            installKeyMonitorIfNeeded()
            runtime.startIfNeeded(
                terminalView: terminalView,
                profile: profile,
                sessionPassword: sessionPassword,
                startupCommand: startupCommand
            )
        }

        private func installKeyMonitorIfNeeded() {
            guard keyMonitor == nil else {
                return
            }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.trackTerminalCommandInput(event)

                guard let self,
                      self.sendControlShortcutIfNeeded(event) else {
                    return event
                }

                return nil
            }
        }

        private func trackTerminalCommandInput(_ event: NSEvent) {
            guard let terminalView,
                  ownsInput(event),
                  let ornithopterTerminalView = terminalView as? OrnithopterTerminalView else {
                return
            }

            ornithopterTerminalView.trackCommandKeyDown(event)
        }

        private func sendControlShortcutIfNeeded(_ event: NSEvent) -> Bool {
            guard let terminalView,
                  ownsInput(event) else {
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

        private func ownsInput(_ event: NSEvent) -> Bool {
            guard let terminalView else { return false }
            return TerminalInputRouting.owns(event, view: terminalView, isActive: isActive)
        }

        func stopMonitoring() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            terminalView = nil
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
    var onFocus: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label("SwiftTerm Not Linked", systemImage: "terminal")
        } description: {
            Text("Open the project in Xcode and let Swift Package Manager resolve SwiftTerm.")
        }
    }
}

#endif
