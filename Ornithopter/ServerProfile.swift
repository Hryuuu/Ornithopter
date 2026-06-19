//
//  ServerProfile.swift
//  Ornithopter
//

import Foundation

struct ServerProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var username: String
    var port: Int
    var identityFile: String
    var remotePath: String
    var passwordAuthentication: Bool
    var savePasswordInKeychain: Bool
    var x11Forwarding: Bool
    var x11TrustedForwarding: Bool
    var hideHiddenFiles: Bool
    var lastConnectedAt: Date?
    var tags: [String]
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        username: String,
        port: Int = 22,
        identityFile: String = "",
        remotePath: String = "~",
        passwordAuthentication: Bool = false,
        savePasswordInKeychain: Bool = false,
        x11Forwarding: Bool = false,
        x11TrustedForwarding: Bool = false,
        hideHiddenFiles: Bool = false,
        lastConnectedAt: Date? = nil,
        tags: [String] = [],
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.port = port
        self.identityFile = identityFile
        self.remotePath = remotePath
        self.passwordAuthentication = passwordAuthentication
        self.savePasswordInKeychain = savePasswordInKeychain
        self.x11Forwarding = x11Forwarding
        self.x11TrustedForwarding = x11TrustedForwarding
        self.hideHiddenFiles = hideHiddenFiles
        self.lastConnectedAt = lastConnectedAt
        self.tags = tags
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case username
        case port
        case identityFile
        case remotePath
        case passwordAuthentication
        case savePasswordInKeychain
        case x11Forwarding
        case x11TrustedForwarding
        case hideHiddenFiles
        case lastConnectedAt
        case tags
        case notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        username = try container.decode(String.self, forKey: .username)
        port = try container.decode(Int.self, forKey: .port)
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? "~"
        passwordAuthentication = try container.decodeIfPresent(Bool.self, forKey: .passwordAuthentication) ?? false
        savePasswordInKeychain = try container.decodeIfPresent(Bool.self, forKey: .savePasswordInKeychain) ?? false
        x11Forwarding = try container.decodeIfPresent(Bool.self, forKey: .x11Forwarding) ?? false
        x11TrustedForwarding = try container.decodeIfPresent(Bool.self, forKey: .x11TrustedForwarding) ?? false
        hideHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .hideHiddenFiles) ?? false
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    nonisolated var displayName: String {
        name.isEmpty ? host : name
    }

    nonisolated var destination: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }

    nonisolated var searchText: String {
        [
            name,
            host,
            username,
            tags.joined(separator: " "),
            notes
        ]
        .joined(separator: " ")
        .lowercased()
    }

}
