//
//  ContentView.swift
//  Ornithopter
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = ProfileStore()
    @State private var selection: ServerProfile.ID?
    @State private var searchText = ""

    private var filteredProfiles: [ServerProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return store.profiles
        }

        return store.profiles.filter { profile in
            [
                profile.name,
                profile.host,
                profile.username,
                profile.tags.joined(separator: " "),
                profile.notes
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
        }
    }

    private var selectedProfile: Binding<ServerProfile>? {
        guard let selection,
              let index = store.profiles.firstIndex(where: { $0.id == selection }) else {
            return nil
        }

        return $store.profiles[index]
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                ServerListHeader(
                    searchText: $searchText,
                    addAction: addProfile
                )

                List(filteredProfiles, selection: $selection) { profile in
                    ServerRow(profile: profile)
                        .tag(profile.id)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let selectedProfile {
                ServerDetailView(
                    profile: selectedProfile,
                    deleteAction: { deleteProfile(selectedProfile.wrappedValue) }
                )
            } else {
                EmptySelectionView(addAction: addProfile)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            if selection == nil {
                selection = store.profiles.first?.id
            }
        }
    }

    private func addProfile() {
        let profile = store.addProfile()
        selection = profile.id
    }

    private func deleteProfile(_ profile: ServerProfile) {
        store.delete(profile)
        selection = store.profiles.first?.id
    }
}

private struct ServerListHeader: View {
    @Binding var searchText: String
    let addAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Ornithopter")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button(action: addAction) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add server")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search servers", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
    }
}

private struct ServerRow: View {
    let profile: ServerProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profile.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if profile.port != 22 {
                    Text("\(profile.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(profile.destination)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !profile.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(profile.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tertiary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ServerDetailView: View {
    @Binding var profile: ServerProfile
    let deleteAction: () -> Void

    private var sshCommand: String {
        SSHCommandBuilder.sshCommand(for: profile)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailHeader(profile: profile, sshCommand: sshCommand)

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("Name", text: $profile.name)
                        TextField("Host", text: $profile.host)

                        HStack {
                            TextField("Username", text: $profile.username)
                            Stepper(value: $profile.port, in: 1...65535) {
                                TextField("Port", value: $profile.port, format: .number)
                                    .frame(width: 96)
                            }
                        }

                        TextField("Identity file", text: $profile.identityFile)
                        TextField("Remote path", text: $profile.remotePath)

                        Toggle(isOn: $profile.x11Forwarding) {
                            Label("X11 forwarding", systemImage: "macwindow")
                        }

                        TagEditor(tags: $profile.tags)

                        TextField("Notes", text: $profile.notes, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(4)
                } label: {
                    Label("Connection", systemImage: "server.rack")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        CommandPreview(command: sshCommand)

                        HStack {
                            Button {
                                SSHSessionWindowManager.open(profile: profile)
                            } label: {
                                Label("Connect", systemImage: "terminal")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                TerminalLauncher.copyToClipboard(sshCommand)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    .padding(4)
                } label: {
                    Label("SSH", systemImage: "network")
                }

                Button(role: .destructive, action: deleteAction) {
                    Label("Delete Server", systemImage: "trash")
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }
}

private struct DetailHeader: View {
    let profile: ServerProfile
    let sshCommand: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(profile.displayName)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Text(profile.host)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(sshCommand)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

private struct TagEditor: View {
    @Binding var tags: [String]
    @State private var tagText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add tag", text: $tagText)
                    .onSubmit(addTag)

                Button(action: addTag) {
                    Image(systemName: "plus")
                }
                .help("Add tag")
            }

            if !tags.isEmpty {
                FlowLayout(items: tags) { tag in
                    HStack(spacing: 4) {
                        Text(tag)
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tertiary, in: Capsule())
                }
            }
        }
    }

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !tags.contains(tag) else {
            return
        }
        tags.append(tag)
        tagText = ""
    }
}

private struct CommandPreview: View {
    let command: String

    var body: some View {
        Text(command)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptySelectionView: View {
    let addAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Server Selected", systemImage: "server.rack")
        } description: {
            Text("Create or select a saved SSH profile.")
        } actions: {
            Button(action: addAction) {
                Label("Add Server", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct FlowLayout<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let items: Data
    let content: (Data.Element) -> Content

    init(items: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(items), id: \.self) { item in
                content(item)
            }
        }
    }
}
