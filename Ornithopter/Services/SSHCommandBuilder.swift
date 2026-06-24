//
//  SSHCommandBuilder.swift
//  Ornithopter
//

import Darwin
import Foundation

enum SSHCommandBuilder {
    nonisolated static func sshArguments(for profile: ServerProfile, startupCommand: String? = nil) -> [String] {
        var arguments: [String] = []
        appendSSHOptions(for: profile, to: &arguments)
        appendX11Options(for: profile, to: &arguments)

        let command = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        if command?.isEmpty == false {
            arguments.append("-t")
        }

        arguments.append(profile.destination)
        if let command, !command.isEmpty {
            arguments.append(command)
        }
        return arguments
    }

    nonisolated static func shellQuotedArgument(_ value: String) -> String {
        if value == "~" {
            return "~"
        }

        if value.hasPrefix("~/") {
            let remainder = String(value.dropFirst(2))
            return remainder.isEmpty ? "~" : "~/\(shellQuote(remainder))"
        }

        return shellQuote(value)
    }

    nonisolated static func folderListArguments(for profile: ServerProfile, path: String) -> [String] {
        var arguments: [String] = []
        appendSSHOptions(for: profile, to: &arguments)
        arguments.append(contentsOf: [
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=5",
            profile.destination,
            "cd \(shellQuote(path)) && find . -maxdepth 1 -type d -print | sed 's#^./##' | sort"
        ])
        return arguments
    }

    nonisolated static func sftpArguments(for profile: ServerProfile, allowPassword: Bool = false) -> [String] {
        var arguments: [String] = ["-o", "ConnectTimeout=5"]
        if !allowPassword {
            arguments.append(contentsOf: ["-b", "-", "-o", "BatchMode=yes"])
        }
        appendSFTPOptions(for: profile, to: &arguments)
        arguments.append(profile.destination)
        return arguments
    }

    nonisolated static func remoteCommandArguments(for profile: ServerProfile, command: String, allowPassword: Bool = false) -> [String] {
        var arguments: [String] = ["-o", "ConnectTimeout=5"]
        if !allowPassword {
            arguments.append(contentsOf: ["-o", "BatchMode=yes"])
        }
        appendSSHOptions(for: profile, to: &arguments)
        arguments.append(profile.destination)
        arguments.append(command)
        return arguments
    }

    nonisolated static func sshCommand(for profile: ServerProfile) -> String {
        var parts = ["ssh"]
        appendCommonOptions(for: profile, portOption: "-p", to: &parts)
        appendX11Options(for: profile, to: &parts)
        parts.append(shellQuote(profile.destination))
        return parts.joined(separator: " ")
    }

    nonisolated static func uploadCommand(for profile: ServerProfile, localPath: String = "<local-path>") -> String {
        var parts = ["scp"]
        appendCommonOptions(for: profile, portOption: "-P", to: &parts)
        parts.append(shellQuote(localPath))
        parts.append(shellQuote("\(profile.destination):\(profile.remotePath)"))
        return parts.joined(separator: " ")
    }

    nonisolated static func downloadCommand(for profile: ServerProfile, localPath: String = ".") -> String {
        var parts = ["scp", "-r"]
        appendCommonOptions(for: profile, portOption: "-P", to: &parts)
        parts.append(shellQuote("\(profile.destination):\(profile.remotePath)"))
        parts.append(shellQuote(localPath))
        return parts.joined(separator: " ")
    }

    private nonisolated static func appendCommonOptions(for profile: ServerProfile, portOption: String, to parts: inout [String]) {
        if profile.port != 22 {
            parts.append(contentsOf: [portOption, "\(profile.port)"])
        }

        if let identityFile = resolvedIdentityFile(for: profile) {
            parts.append(contentsOf: ["-i", shellQuote(identityFile)])
        }
    }

    private nonisolated static func appendSSHOptions(for profile: ServerProfile, to arguments: inout [String]) {
        if profile.port != 22 {
            arguments.append(contentsOf: ["-p", "\(profile.port)"])
        }

        if let identityFile = resolvedIdentityFile(for: profile) {
            arguments.append(contentsOf: ["-i", identityFile])
        }
    }

    private nonisolated static func appendSFTPOptions(for profile: ServerProfile, to arguments: inout [String]) {
        if profile.port != 22 {
            arguments.append(contentsOf: ["-P", "\(profile.port)"])
        }

        if let identityFile = resolvedIdentityFile(for: profile) {
            arguments.append(contentsOf: ["-i", identityFile])
        }
    }

    private nonisolated static func appendX11Options(for profile: ServerProfile, to arguments: inout [String]) {
        if profile.x11Forwarding {
            arguments.append(profile.x11TrustedForwarding ? "-Y" : "-X")
        }
    }

    private nonisolated static func resolvedIdentityFile(for profile: ServerProfile) -> String? {
        guard !profile.passwordAuthentication, profile.customIdentityFileEnabled else {
            return nil
        }

        let value = profile.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        let expanded = expandedHomePath(value)
        guard FileManager.default.fileExists(atPath: expanded) else {
            return nil
        }

        return expanded
    }

    private nonisolated static func expandedHomePath(_ value: String) -> String {
        guard value == "~" || value.hasPrefix("~/") else {
            return value
        }

        let home = realUserHomeDirectory()
        if value == "~" {
            return home
        }
        return home + String(value.dropFirst())
    }

    private nonisolated static func realUserHomeDirectory() -> String {
        guard let passwd = getpwuid(getuid()),
              let home = passwd.pointee.pw_dir else {
            return NSHomeDirectory()
        }

        return String(cString: home)
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
