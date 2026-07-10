//
//  SSHPasswordSupport.swift
//  Ornithopter
//

import AppKit
import Darwin
import Foundation
import LocalAuthentication
import Security

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

nonisolated final class SSHAskPassSession: @unchecked Sendable {
    private(set) var environment: [String: String] = [:]

    private let password: String
    private let directoryURL: URL
    private let helperURL: URL
    private let fifoURL: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stopped = false

    init?(password: String?) {
        guard let password, !password.isEmpty else {
            return nil
        }

        self.password = password
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ornithopter-askpass-\(UUID().uuidString)", isDirectory: true)
        helperURL = directoryURL.appendingPathComponent("askpass.sh")
        fifoURL = directoryURL.appendingPathComponent("password.fifo")
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
            "ORNITHOPTER_ASKPASS_FIFO": fifoURL.path
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
        cleanup()
    }

    private func startWriter() {
        let fifoPath = fifoURL.path
        let output = Array((password + "\n").utf8)

        queue.async { [weak self] in
            while self?.isStopped == false {
                let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
                if fd < 0 {
                    if errno == ENXIO || errno == EINTR {
                        usleep(50_000)
                        continue
                    }
                    break
                }

                output.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        return
                    }

                    var written = 0
                    while written < buffer.count {
                        let count = write(fd, baseAddress.advanced(by: written), buffer.count - written)
                        if count <= 0 {
                            break
                        }
                        written += count
                    }
                }
                close(fd)
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
