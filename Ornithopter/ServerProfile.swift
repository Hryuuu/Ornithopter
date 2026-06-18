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
    var x11Forwarding: Bool
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
        x11Forwarding: Bool = false,
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
        self.x11Forwarding = x11Forwarding
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
        case x11Forwarding
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
        identityFile = try container.decode(String.self, forKey: .identityFile)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        x11Forwarding = try container.decodeIfPresent(Bool.self, forKey: .x11Forwarding) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    nonisolated var displayName: String {
        name.isEmpty ? host : name
    }

    nonisolated var destination: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }

    static let sampleProfiles: [ServerProfile] = [
        ServerProfile(
            name: "Research GPU",
            host: "gpu.lab.example",
            username: "hryu",
            port: 2222,
            remotePath: "~/workspace",
            notes: "PyTorch experiments and long-running training jobs."
        ),
        ServerProfile(
            name: "Production API",
            host: "api.example.com",
            username: "deploy",
            remotePath: "/srv/app",
            notes: "Use read-only commands unless deploying from CI."
        )
    ]
}
