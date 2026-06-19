//
//  ConnectionWindow.swift
//  Ornithopter
//

import AppKit
import SwiftUI

enum SSHSessionWindowManager {
    private static var windows: [NSWindow] = []
    private static let initialWindowSize = NSSize(width: 1120, height: 720)
    private static let minimumWindowSize = NSSize(width: 920, height: 560)

    @discardableResult
    static func open(profile: ServerProfile) -> Bool {
        let sessionPassword = SSHPasswordPrompter.passwordForConnection(profile: profile)
        if profile.passwordAuthentication && sessionPassword == nil {
            return false
        }

        let controller = NSHostingController(
            rootView: ConnectionWindowView(profile: profile, sessionPassword: sessionPassword)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = profile.displayName
        window.titleVisibility = .visible
        window.setContentSize(initialWindowSize)
        window.minSize = minimumWindowSize
        window.contentMinSize = minimumWindowSize
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
        return true
    }
}

struct ConnectionWindowView: View {
    let profile: ServerProfile
    let sessionPassword: String?
    @State private var terminalID = UUID()
    @State private var isExplorerVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isExplorerVisible {
                RemoteFolderBrowser(
                    profile: profile,
                    sessionPassword: sessionPassword,
                    collapseAction: {
                        isExplorerVisible = false
                    }
                )
                .frame(width: 240)
            } else {
                VStack {
                    Button {
                        isExplorerVisible = true
                    } label: {
                        Image(systemName: "sidebar.leading")
                    }
                    .buttonStyle(.borderless)
                    .help("Show Explorer")

                    Spacer()
                }
                .padding(.top, 8)
                .frame(width: 32)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            Divider()

            VStack(spacing: 0) {
                TerminalTextView(
                    profile: profile,
                    sessionPassword: sessionPassword,
                    onRunningChanged: { _ in },
                    onUnexpectedExit: { status in
                        DispatchQueue.main.async {
                            if confirmReconnect(status: status) {
                                terminalID = UUID()
                            }
                        }
                    }
                )
                .id(terminalID)
            }
            .frame(minWidth: 620)
        }
        .frame(minWidth: 920, minHeight: 560)
    }

    private func confirmReconnect(status: Int32) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SSH connection closed"
        alert.informativeText = "The session ended unexpectedly with status \(status)."
        alert.addButton(withTitle: "Reconnect")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }
}
