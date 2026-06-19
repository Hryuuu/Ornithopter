//
//  ProfileStore.swift
//  Ornithopter
//

import Combine
import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [ServerProfile] {
        didSet {
            save()
        }
    }

    private let storageKey = "ornithopter.serverProfiles"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let profiles = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            self.profiles = profiles
        } else {
            self.profiles = []
        }
    }

    func addProfile() -> ServerProfile {
        let defaultIdentityFile = UserDefaults.standard
            .string(forKey: "defaultIdentityFile")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? AppPreferenceDefaults.defaultIdentityFile

        let profile = ServerProfile(
            name: nextNewServerName(),
            host: "",
            username: "",
            identityFile: defaultIdentityFile,
            passwordAuthentication: true,
            savePasswordInKeychain: true,
            x11Forwarding: false
        )
        profiles.insert(profile, at: 0)
        return profile
    }

    func update(_ profile: ServerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        profiles[index] = profile
    }

    func delete(_ profile: ServerProfile) {
        SSHPasswordKeychain.deletePassword(for: profile)
        profiles.removeAll { $0.id == profile.id }
    }

    func markConnected(_ profile: ServerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }

        profiles[index].lastConnectedAt = Date()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func nextNewServerName() -> String {
        let prefix = "New Server"
        let usedNumbers = Set(profiles.compactMap { profile -> Int? in
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.hasPrefix(prefix) else {
                return nil
            }

            let suffix = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(suffix)
        })

        var number = 1
        while usedNumbers.contains(number) {
            number += 1
        }
        return "\(prefix) \(number)"
    }
}
