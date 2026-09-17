//
//  SSHPasswordSupport.swift
//  Ornithopter
//

import AppKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import OSLog

extension Notification.Name {
    static let ornithopterSavedSSHPasswordsDidChange = Notification.Name("Ornithopter.savedSSHPasswordsDidChange")
}

struct SSHPasswordPromptResult {
    let password: String
    let saveInKeychain: Bool
}

struct SSHConnectionPasswordResult {
    let password: String?
    let shouldEnableKeychainSaving: Bool
}

enum SSHPasswordMemoryCache {
    private static let lock = NSLock()
    private static var passwords: [ServerProfile.ID: String] = [:]

    static func password(for profile: ServerProfile) -> String? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return passwords[profile.id]
    }

    static func store(_ password: String, for profile: ServerProfile) {
        lock.lock()
        passwords[profile.id] = password
        lock.unlock()
    }

    static func removePassword(for profile: ServerProfile) {
        lock.lock()
        passwords.removeValue(forKey: profile.id)
        lock.unlock()
    }

    static func removeAllPasswords() {
        lock.lock()
        passwords.removeAll()
        lock.unlock()
    }
}

enum SSHPasswordKeychain {
    private static let service = "kucc.co.kr.Ornithopter.ssh-password"
    private static let accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    static func hasPassword(for profile: ServerProfile) -> Bool {
        if SSHPasswordMemoryCache.password(for: profile) != nil {
            return true
        }

        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString,
            kSecUseAuthenticationContext as String: context,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }
        return false
    }

    static func password(for profile: ServerProfile) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        migratePasswordAttributesIfNeeded(for: profile)
        guard let password = String(data: data, encoding: .utf8) else {
            return nil
        }

        SSHPasswordMemoryCache.store(password, for: profile)
        return password
    }

    @discardableResult
    static func save(_ password: String, for profile: ServerProfile) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString
        ]

        let attributes: [String: Any] = [
            kSecAttrLabel as String: "Ornithopter \(profile.displayName)",
            kSecAttrAccessible as String: accessible,
            kSecValueData as String: Data(password.utf8)
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            SSHPasswordMemoryCache.store(password, for: profile)
            notifyPasswordsChanged()
            return status
        }

        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString,
            kSecAttrLabel as String: "Ornithopter \(profile.displayName)",
            kSecAttrAccessible as String: accessible,
            kSecValueData as String: Data(password.utf8)
        ]

        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecSuccess {
                SSHPasswordMemoryCache.store(password, for: profile)
                notifyPasswordsChanged()
            }
            return addStatus
        }

        return status
    }

    static func deletePassword(for profile: ServerProfile) {
        SSHPasswordMemoryCache.removePassword(for: profile)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            notifyPasswordsChanged()
        }
    }

    @discardableResult
    static func deleteAllPasswords() -> OSStatus {
        SSHPasswordMemoryCache.removeAllPasswords()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            notifyPasswordsChanged()
        }
        return status
    }

    private static func notifyPasswordsChanged() {
        NotificationCenter.default.post(name: .ornithopterSavedSSHPasswordsDidChange, object: nil)
    }

    private static func migratePasswordAttributesIfNeeded(for profile: ServerProfile) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: accessible
        ]

        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}

enum SSHPasswordPrompter {
    static func passwordForConnection(profile: ServerProfile) -> SSHConnectionPasswordResult? {
        guard profile.passwordAuthentication else {
            return SSHConnectionPasswordResult(password: nil, shouldEnableKeychainSaving: false)
        }

        if profile.savePasswordInKeychain {
            if let password = SSHPasswordMemoryCache.password(for: profile),
               !password.isEmpty {
                return SSHConnectionPasswordResult(password: password, shouldEnableKeychainSaving: false)
            }

            if let password = SSHPasswordKeychain.password(for: profile),
               !password.isEmpty {
                return SSHConnectionPasswordResult(password: password, shouldEnableKeychainSaving: false)
            }
        }

        guard let result = requestPassword(
            title: String(format: NSLocalizedString("Password for %@", comment: "SSH password prompt title"), profile.displayName),
            message: String(format: NSLocalizedString("Enter the SSH password for %@.", comment: "SSH password prompt message"), profile.destination),
            confirmTitle: NSLocalizedString("Connect", comment: "Connect button"),
            allowSaving: true,
            saveByDefault: profile.savePasswordInKeychain
        ) else {
            return nil
        }

        let saveStatus = result.saveInKeychain
            ? SSHPasswordKeychain.save(result.password, for: profile)
            : errSecSuccess

        return SSHConnectionPasswordResult(
            password: result.password,
            shouldEnableKeychainSaving: result.saveInKeychain &&
                saveStatus == errSecSuccess &&
                !profile.savePasswordInKeychain
        )
    }

    @discardableResult
    static func updateKeychainPassword(for profile: ServerProfile) -> Bool {
        let isUpdating = SSHPasswordKeychain.hasPassword(for: profile)

        guard let result = requestPassword(
            title: isUpdating
                ? NSLocalizedString("Update Password", comment: "Update password prompt title")
                : NSLocalizedString("Save Password", comment: "Save password prompt title"),
            message: isUpdating
                ? NSLocalizedString("Enter a new SSH password to update the saved Keychain item.", comment: "Update keychain password message")
                : NSLocalizedString("Enter the SSH password to store in macOS Keychain.", comment: "Save keychain password message"),
            confirmTitle: isUpdating
                ? NSLocalizedString("Update", comment: "Update button")
                : NSLocalizedString("Save", comment: "Save button"),
            allowSaving: false,
            saveByDefault: true
        ) else {
            return false
        }

        return SSHPasswordKeychain.save(result.password, for: profile) == errSecSuccess
    }

    static func requestPassword(
        title: String,
        message: String,
        confirmTitle: String,
        allowSaving: Bool,
        saveByDefault: Bool
    ) -> SSHPasswordPromptResult? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: allowSaving ? 58 : 28)

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        passwordField.placeholderString = NSLocalizedString("Password", comment: "Password field placeholder")
        stack.addArrangedSubview(passwordField)

        let saveButton = NSButton(
            checkboxWithTitle: NSLocalizedString("Save in Keychain", comment: "Save password in Keychain checkbox"),
            target: nil,
            action: nil
        )
        if allowSaving {
            saveButton.state = saveByDefault ? .on : .off
            stack.addArrangedSubview(saveButton)
        }

        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let password = passwordField.stringValue
        guard !password.isEmpty else {
            return nil
        }

        return SSHPasswordPromptResult(
            password: password,
            saveInKeychain: allowSaving && saveButton.state == .on
        )
    }
}

enum SSHProcessEnvironment {
    nonisolated static func baseEnvironment() -> [String: String] {
        let allowedKeys = [
            "PATH",
            "HOME",
            "USER",
            "LOGNAME",
            "SHELL",
            "TERM",
            "LANG",
            "LC_CTYPE",
            "TMPDIR",
            "SSH_AUTH_SOCK",
            "DISPLAY"
        ]
        let source = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in allowedKeys {
            if let value = source[key], !value.isEmpty {
                environment[key] = value
            }
        }

        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["LC_CTYPE"] = environment["LC_CTYPE"] ?? "en_US.UTF-8"
        environment["DISPLAY"] = environment["DISPLAY"] ?? "ornithopter:0"
        return environment
    }
}

nonisolated enum SSHAuthenticationPrompt: Equatable {
    case hostKey, password, confirmation, secret

    static func classify(_ prompt: String, hint: String) -> Self {
        if prompt.contains("Are you sure you want to continue connecting") {
            return .hostKey
        }
        if hint == "confirm" { return .confirmation }
        if prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("password:") {
            return .password
        }
        return .secret
    }
}

@MainActor
private enum SSHAuthenticationPrompter {
    private static var acceptedHostPrompts: Set<String> = []
    private static var pending: [() -> Void] = []
    private static var presenting = false

    static func enqueue(_ action: @escaping () -> Void) {
        pending.append(action)
        guard !presenting else { return }
        presenting = true
        while !pending.isEmpty { pending.removeFirst()() }
        presenting = false
    }

    static func response(to prompt: String, hint: String, password: String?, session: SSHAskPassSession) -> String {
        guard !session.isStopped else { return "no" }
        let kind = SSHAuthenticationPrompt.classify(prompt, hint: hint)
        if kind == .password, let password { return password }
        if kind == .hostKey, acceptedHostPrompts.contains(prompt) { return "yes" }

        let alert = NSAlert()
        alert.informativeText = prompt
        let isConfirmation = kind == .hostKey || kind == .confirmation
        alert.messageText = NSLocalizedString(kind == .hostKey ? "Verify Server Identity" : "SSH Authentication", comment: "")
        alert.alertStyle = isConfirmation ? .warning : .informational
        alert.addButton(withTitle: NSLocalizedString(isConfirmation ? "Cancel" : "Continue", comment: ""))
        alert.addButton(withTitle: NSLocalizedString(kind == .hostKey ? "Trust and Connect" : (isConfirmation ? "Continue" : "Cancel"), comment: ""))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        if !isConfirmation {
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
        }
        session.setPromptAlert(alert)
        defer { session.setPromptAlert(nil) }
        let approved = alert.runModal() == (isConfirmation ? .alertSecondButtonReturn : .alertFirstButtonReturn) && !session.isStopped
        guard approved else { return isConfirmation ? "no" : "" }
        if kind == .hostKey { acceptedHostPrompts.insert(prompt) }
        return isConfirmation ? "yes" : field.stringValue
    }
}

nonisolated final class SSHAskPassSession: @unchecked Sendable {
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ value: String) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }
    private static let logger = Logger(subsystem: "kucc.co.kr.Ornithopter", category: "SSHAskPass")
    private(set) var environment: [String: String] = [:]

    private let password: String?
    private let promptResponse: (@Sendable (String, String) -> String)?
    private let directoryURL: URL
    private let helperURL: URL
    private let fifoURL: URL
    private let requestURL: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stopped = false
    @MainActor private weak var promptAlert: NSAlert?

    @MainActor fileprivate func setPromptAlert(_ alert: NSAlert?) { promptAlert = alert }

    init?(password: String?, promptResponse: (@Sendable (String, String) -> String)? = nil) {
        self.password = password
        self.promptResponse = promptResponse
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ornithopter-askpass-\(UUID().uuidString)", isDirectory: true)
        helperURL = directoryURL.appendingPathComponent("askpass.sh")
        fifoURL = directoryURL.appendingPathComponent("password.fifo")
        requestURL = directoryURL.appendingPathComponent("request")
        queue = DispatchQueue(label: "kr.co.kucc.Ornithopter.askpass.\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        } catch {
            return nil
        }

        guard mkfifo(fifoURL.path, 0o600) == 0 else {
            cleanup()
            return nil
        }

        let script = """
        #!/bin/sh
        [ "${SSH_ASKPASS_PROMPT:-}" = none ] && exit 0
        umask 077
        printf '%s\\000%s\\000' "${SSH_ASKPASS_PROMPT:-}" "$1" > "$ORNITHOPTER_ASKPASS_REQUEST.tmp" || exit 1
        /bin/mv "$ORNITHOPTER_ASKPASS_REQUEST.tmp" "$ORNITHOPTER_ASKPASS_REQUEST" || exit 1
        /bin/cat "$ORNITHOPTER_ASKPASS_FIFO"
        """

        do {
            try script.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
        } catch {
            cleanup()
            return nil
        }

        environment = [
            "SSH_ASKPASS": helperURL.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "ORNITHOPTER_ASKPASS_FIFO": fifoURL.path,
            "ORNITHOPTER_ASKPASS_REQUEST": requestURL.path
        ]
        startWriter()
    }

    deinit {
        stop()
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()

        guard !wasStopped else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let alert = self?.promptAlert else { return }
            if NSApp.modalWindow === alert.window { NSApp.abortModal() }
            alert.window.orderOut(nil)
        }
        // Wake a helper already blocked opening/reading the FIFO when its SSH
        // parent exits or the user closes the terminal during a prompt.
        let fd = open(fifoURL.path, O_WRONLY | O_NONBLOCK)
        if fd >= 0 {
            try? ProcessPipeWriter.write(Data("no\n".utf8), to: fd, timeout: 0.1)
            close(fd)
        }
        cleanup()
    }

    private func startWriter() {
        let fifoPath = fifoURL.path
        let requestURL = requestURL

        queue.async { [weak self] in
            while self?.isStopped == false {
                guard let data = try? Data(contentsOf: requestURL) else {
                    usleep(50_000)
                    continue
                }
                try? FileManager.default.removeItem(at: requestURL)
                let fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
                guard fields.count == 3, fields.last == "" else { break }
                let hint = String(fields[0])
                let prompt = String(fields[1])
                let reply = Reply()
                if let provider = self?.promptResponse {
                    reply.set(provider(prompt, hint))
                } else if SSHAuthenticationPrompt.classify(prompt, hint: hint) == .password, let password = self?.password {
                    reply.set(password)
                } else {
                    DispatchQueue.main.async { [weak self] in
                        SSHAuthenticationPrompter.enqueue { [weak self] in
                            guard let self else { reply.set("no"); return }
                            reply.set(SSHAuthenticationPrompter.response(to: prompt, hint: hint, password: self.password, session: self))
                        }
                    }
                }
                while reply.get() == nil && self?.isStopped == false { usleep(50_000) }
                guard self?.isStopped == false, let response = reply.get() else { break }
                let output = Data((response + "\n").utf8)
                var fd: Int32 = -1
                while self?.isStopped == false {
                    fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
                    if fd >= 0 || (errno != ENXIO && errno != EINTR) { break }
                    usleep(50_000)
                }
                if fd < 0 {
                    break
                }

                do {
                    // A cancelled authentication helper may close its FIFO before
                    // this write. Suppress SIGPIPE on this descriptor only.
                    if self?.isStopped == false {
                        try ProcessPipeWriter.write(output, to: fd, timeout: 2)
                    }
                } catch {
                    Self.logger.error("Askpass pipe write failed: \((error as NSError).code)")
                    close(fd)
                    break
                }
                close(fd)
            }
        }
    }

    fileprivate var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
