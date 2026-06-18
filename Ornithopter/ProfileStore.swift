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
            self.profiles = ServerProfile.sampleProfiles
        }
    }

    func addProfile() -> ServerProfile {
        let profile = ServerProfile(
            name: "New Server",
            host: "example.com",
            username: NSUserName()
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
        profiles.removeAll { $0.id == profile.id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
