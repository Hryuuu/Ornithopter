//
//  ContentView.swift
//  Ornithopter
//

import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var store = ProfileStore()
    @State private var selection: ServerProfile.ID?
    @State private var searchText = ""
    @State private var scrollTarget: ServerProfile.ID?

    private var filteredProfiles: [ServerProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let profiles = query.isEmpty ? store.profiles : store.profiles.filter { profile in
            profile.searchText.contains(query)
        }

        return sortedProfiles(profiles)
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
                    searchText: $searchText
                )

                ScrollViewReader { proxy in
                    List(filteredProfiles, selection: $selection) { profile in
                        ServerRow(profile: profile)
                            .tag(profile.id)
                            .id(profile.id)
                    }
                    .listStyle(.sidebar)
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else {
                            return
                        }

                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                proxy.scrollTo(target, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: searchText) { _, _ in
                        guard let firstResult = filteredProfiles.first?.id else {
                            return
                        }

                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                proxy.scrollTo(firstResult, anchor: .top)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let selectedProfile {
                ServerDetailView(
                    profile: selectedProfile,
                    connectAction: connect,
                    deleteAction: { deleteProfile(selectedProfile.wrappedValue) }
                )
            } else {
                EmptySelectionView(addAction: addProfile)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(
            WindowSizeConfigurator(
                initialWidth: 820,
                initialHeight: 790,
                minimumWidth: 800,
                minimumHeight: 500
            )
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: addProfile) {
                    Image(systemName: "plus")
                }
                .help("Add server")
            }
        }
        .onAppear {
            if selection == nil {
                selection = filteredProfiles.first?.id
            }
        }
    }

    private func sortedProfiles(_ profiles: [ServerProfile]) -> [ServerProfile] {
        profiles.sorted { lhs, rhs in
            switch (lhs.lastConnectedAt, rhs.lastConnectedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private func addProfile() {
        let profile = store.addProfile()
        searchText = ""
        selection = profile.id
        scrollTarget = profile.id
    }

    private func deleteProfile(_ profile: ServerProfile) {
        store.delete(profile)
        selection = filteredProfiles.first?.id
    }

    private func connect(_ profile: ServerProfile) {
        if SSHSessionWindowManager.open(profile: profile) {
            store.markConnected(profile)
        }
    }
}

private struct WindowSizeConfigurator: NSViewRepresentable {
    let initialWidth: CGFloat
    let initialHeight: CGFloat
    let minimumWidth: CGFloat
    let minimumHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView, context: context)
    }

    private func configureWindow(for view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else {
                return
            }

            let minimumSize = NSSize(width: minimumWidth, height: minimumHeight)
            window.minSize = minimumSize

            guard !context.coordinator.didSetInitialSize else {
                return
            }

            context.coordinator.didSetInitialSize = true
            window.setContentSize(NSSize(width: initialWidth, height: initialHeight))
        }
    }

    final class Coordinator {
        var didSetInitialSize = false
    }
}

private struct ServerListHeader: View {
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 0) {
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
                    Text(verbatim: String(profile.port))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Host not set")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(profile.destination)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

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
    let connectAction: (ServerProfile) -> Void
    let deleteAction: () -> Void
    @State private var hasStoredKeychainPassword = false

    private var canConnect: Bool {
        !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSaveKeychainPassword: Bool {
        profile.passwordAuthentication &&
        profile.savePasswordInKeychain &&
        canConnect
    }

    private var showsFileBrowser: Binding<Bool> {
        Binding(
            get: { !profile.disableExplorer },
            set: { profile.disableExplorer = !$0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(profile: profile, canConnect: canConnect, connectAction: connectAction)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
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
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(4)
                } label: {
                    Label("Default", systemImage: "server.rack")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsToggleRow(isOn: $profile.passwordAuthentication, title: "Password authentication", systemImage: "key")

                        HStack(alignment: .center, spacing: 10) {
                            SettingsToggleRow(isOn: $profile.savePasswordInKeychain, title: "Save password in Keychain", systemImage: "lock")
                                .disabled(!profile.passwordAuthentication)
                                .opacity(profile.passwordAuthentication ? 1 : 0.55)

                            Spacer()

                            Button {
                                if SSHPasswordPrompter.updateKeychainPassword(for: profile) {
                                    hasStoredKeychainPassword = true
                                }
                            } label: {
                                Label(
                                    hasStoredKeychainPassword ? "Update Keychain Password..." : "Set Keychain Password...",
                                    systemImage: "key.fill"
                                )
                            }
                            .controlSize(.small)
                            .font(.caption)
                            .disabled(!canSaveKeychainPassword)
                            .help(canConnect ? "Save or update the password for this server." : "Enter a host and username first.")
                        }
                        .frame(minHeight: 24)

                        SettingsToggleRow(isOn: $profile.x11Forwarding, title: "X11 forwarding", systemImage: "display")

                        SettingsToggleRow(isOn: $profile.x11TrustedForwarding, title: "Trusted forwarding (-Y)", systemImage: "lock.shield")
                            .disabled(!profile.x11Forwarding)
                            .opacity(profile.x11Forwarding ? 1 : 0.55)
                            .help("Off uses -X. On uses -Y.")

                        SettingsToggleRow(isOn: $profile.hideHiddenFiles, title: "Hide hidden files", systemImage: "eye.slash")

                        SettingsToggleRow(isOn: showsFileBrowser, title: "Show file browser", systemImage: "folder")
                    }
                    .padding(4)
                } label: {
                    Label("Options", systemImage: "checklist")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        TagEditor(tags: $profile.tags)

                        TextField("Notes", text: $profile.notes, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(4)
                } label: {
                    Label("Tags & Notes", systemImage: "tag")
                }

                HStack {
                    Spacer()

                    Button(role: .destructive) {
                        confirmDelete()
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onAppear(perform: refreshKeychainState)
        .onChange(of: profile.id) { _, _ in
            refreshKeychainState()
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(profile.displayName)?"
        alert.informativeText = "This server profile will be removed from Ornithopter."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        deleteAction()
    }

    private func refreshKeychainState() {
        guard canConnect else {
            hasStoredKeychainPassword = false
            return
        }

        hasStoredKeychainPassword = SSHPasswordKeychain.hasPassword(for: profile)
    }
}

private struct SettingsToggleRow: View {
    @Binding var isOn: Bool
    let title: String
    let systemImage: String

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsToggleLabel(title, systemImage: systemImage)
        }
        .frame(minHeight: 24, alignment: .center)
    }
}

private struct SettingsToggleLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 18, alignment: .center)

            Text(title)
        }
    }
}

private struct DetailHeader: View {
    let profile: ServerProfile
    let canConnect: Bool
    let connectAction: (ServerProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(profile.displayName)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Button {
                    connectAction(profile)
                } label: {
                    Label("Connect", systemImage: "terminal")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canConnect)
                .help(canConnect ? "Connect to server" : "Enter host and username to connect")
            }
        }
    }
}

private struct TagEditor: View {
    private let maxTagLength = 18
    private let maxTagCount = 5
    @Binding var tags: [String]
    @State private var tagText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add tag", text: limitedTagText)
                    .onSubmit(addTag)
                    .disabled(tags.count >= maxTagCount)

                Button(action: addTag) {
                    Image(systemName: "plus")
                }
                .disabled(!canAddTag)
                .help("Add tag")
            }

            if !tags.isEmpty {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 5) {
                            Text(tag)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: 132, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                        }
                    }
                }
            }
        }
    }

    private var limitedTagText: Binding<String> {
        Binding(
            get: { tagText },
            set: { tagText = String($0.prefix(maxTagLength)) }
        )
    }

    private var normalizedTag: String {
        String(tagText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTagLength))
    }

    private var canAddTag: Bool {
        !normalizedTag.isEmpty &&
        !tags.contains(normalizedTag) &&
        tags.count < maxTagCount
    }

    private func addTag() {
        let tag = normalizedTag
        guard canAddTag else {
            tagText = ""
            return
        }
        tags.append(tag)
        tagText = ""
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
