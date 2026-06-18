//
//  ConnectionWindow.swift
//  Ornithopter
//

import AppKit
import SwiftUI

enum SSHSessionWindowManager {
    private static var windows: [NSWindow] = []

    static func open(profile: ServerProfile) {
        let controller = NSHostingController(rootView: ConnectionWindowView(profile: profile))
        let window = NSWindow(contentViewController: controller)
        window.title = ""
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.minSize = NSSize(width: 860, height: 520)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        windows.append(window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            windows.removeAll { $0 === window }
        }

        window.makeKeyAndOrderFront(nil)
    }
}

struct ConnectionWindowView: View {
    let profile: ServerProfile
    @State private var isRunning = false
    @State private var showReconnectPrompt = false
    @State private var disconnectStatus: Int32 = 0
    @State private var terminalID = UUID()

    var body: some View {
        HSplitView {
            RemoteFolderBrowser(profile: profile)
                .frame(minWidth: 180, idealWidth: 195, maxWidth: 300)

            VStack(spacing: 0) {
                HStack {
                    Label(profile.displayName, systemImage: isRunning ? "checkmark.circle.fill" : "terminal")
                        .foregroundStyle(isRunning ? .green : .secondary)

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)

                TerminalTextView(
                    profile: profile,
                    onRunningChanged: { isRunning = $0 },
                    onUnexpectedExit: { status in
                        disconnectStatus = status
                        showReconnectPrompt = true
                    }
                )
                .id(terminalID)
            }
            .frame(minWidth: 620)
        }
        .alert("SSH connection closed", isPresented: $showReconnectPrompt) {
            Button("Reconnect") {
                terminalID = UUID()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The session ended unexpectedly with status \(disconnectStatus).")
        }
    }
}
