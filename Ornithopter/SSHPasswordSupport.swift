//
//  SSHPasswordSupport.swift
//  Ornithopter
//

import AppKit
import Foundation
import Security

struct SSHPasswordPromptResult {
    let password: String
    let saveInKeychain: Bool
}

enum SSHPasswordKeychain {
    private static let service = "kucc.co.kr.Ornithopter.ssh-password"

    static func hasPassword(for profile: ServerProfile) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
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

        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for profile: ServerProfile) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString
        ]

        let attributes: [String: Any] = [
            kSecAttrLabel as String: "Ornithopter \(profile.displayName)",
            kSecValueData as String: Data(password.utf8)
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }

        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString,
            kSecAttrLabel as String: "Ornithopter \(profile.displayName)",
            kSecValueData as String: Data(password.utf8)
        ]

        if status == errSecItemNotFound {
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func deletePassword(for profile: ServerProfile) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString
        ]

        SecItemDelete(query as CFDictionary)
    }
}

enum SSHPasswordPrompter {
    static func passwordForConnection(profile: ServerProfile) -> String? {
        guard profile.passwordAuthentication else {
            return nil
        }

        if profile.savePasswordInKeychain,
           let password = SSHPasswordKeychain.password(for: profile),
           !password.isEmpty {
            return password
        }

        guard let result = requestPassword(
            title: "Password for \(profile.displayName)",
            message: "Enter the SSH password for \(profile.destination).",
            confirmTitle: "Connect",
            allowSaving: true,
            saveByDefault: profile.savePasswordInKeychain
        ) else {
            return nil
        }

        if result.saveInKeychain {
            SSHPasswordKeychain.save(result.password, for: profile)
        }

        return result.password
    }

    @discardableResult
    static func updateKeychainPassword(for profile: ServerProfile) -> Bool {
        let isUpdating = SSHPasswordKeychain.hasPassword(for: profile)

        guard let result = requestPassword(
            title: isUpdating ? "Update Password" : "Save Password",
            message: isUpdating
                ? "Enter a new SSH password to update the saved Keychain item."
                : "Enter the SSH password to store in macOS Keychain.",
            confirmTitle: isUpdating ? "Update" : "Save",
            allowSaving: false,
            saveByDefault: true
        ) else {
            return false
        }

        SSHPasswordKeychain.save(result.password, for: profile)
        return true
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
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: allowSaving ? 58 : 28)

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        passwordField.placeholderString = "Password"
        stack.addArrangedSubview(passwordField)

        let saveButton = NSButton(checkboxWithTitle: "Save in Keychain", target: nil, action: nil)
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

enum SSHAskPass {
    nonisolated static func environment(password: String?) -> [String: String] {
        guard let password, !password.isEmpty else {
            return [:]
        }

        guard let helperURL = helperURL() else {
            return [:]
        }

        return [
            "SSH_ASKPASS": helperURL.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? "ornithopter:0",
            "ORNITHOPTER_SSH_PASSWORD": password
        ]
    }

    private nonisolated static func helperURL() -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ornithopter-ssh-askpass.sh")

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let script = """
        #!/bin/sh
        printf '%s\\n' "$ORNITHOPTER_SSH_PASSWORD"
        """

        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}
