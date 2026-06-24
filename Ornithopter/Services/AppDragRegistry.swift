//
//  AppDragRegistry.swift
//  Ornithopter
//

import Foundation
import UniformTypeIdentifiers

enum AppDragTypes {
    static let terminalTab: UTType = .plainText
}

struct RemoteFileDragPayload {
    let profile: ServerProfile
    let sessionPassword: String?
    let items: [RemoteFileItem]
}

@MainActor
enum AppDragRegistry {
    private static var remoteFilePayloads: [UUID: RemoteFileDragPayload] = [:]
    private static var activeRemoteFileToken: UUID?

    static func beginRemoteFileDrag(payload: RemoteFileDragPayload) -> UUID {
        let token = UUID()
        remoteFilePayloads[token] = payload
        activeRemoteFileToken = token
        scheduleRemoteFileCleanup(token)
        return token
    }

    static var activeRemoteFilePayload: (token: UUID, payload: RemoteFileDragPayload)? {
        guard let token = activeRemoteFileToken,
              let payload = remoteFilePayloads[token] else {
            return nil
        }

        return (token, payload)
    }

    static func remoteFilePayload(for token: UUID) -> RemoteFileDragPayload? {
        remoteFilePayloads[token]
    }

    static func endRemoteFileDrag(_ token: UUID) {
        remoteFilePayloads[token] = nil
        if activeRemoteFileToken == token {
            activeRemoteFileToken = nil
        }
    }

    static func clearActiveRemoteFileDrag(_ token: UUID) {
        if activeRemoteFileToken == token {
            activeRemoteFileToken = nil
        }
    }

    nonisolated static func token(from data: Data?) -> UUID? {
        guard let data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return UUID(uuidString: string)
    }

    private static func scheduleRemoteFileCleanup(_ token: UUID) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            endRemoteFileDrag(token)
        }
    }
}
