import AppKit
import UniformTypeIdentifiers

/// Adapts the existing lazy download provider to AppKit's file promises. Remote
/// drops carry only the token and never request/download the promised file.
nonisolated final class RemoteFilePromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    static let remoteType = NSPasteboard.PasteboardType("kr.co.kucc.Ornithopter.remote-files")
    let token: UUID
    private let provider: NSItemProvider
    private let promisedName: String
    private let typeIdentifier: String

    init(provider: NSItemProvider, token: UUID, name: String, typeIdentifier: String) {
        self.provider = provider
        self.token = token
        self.promisedName = name
        self.typeIdentifier = typeIdentifier
        super.init()
        fileType = typeIdentifier
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [Self.remoteType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.remoteType ? token.uuidString : super.pasteboardPropertyList(forType: type)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        promisedName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { source, error in
            if let error { completionHandler(error); return }
            guard let source else { completionHandler(CocoaError(.fileReadUnknown)); return }
            do {
                // The representation URL is valid only during this callback.
                try FileManager.default.copyItem(at: source, to: url)
                completionHandler(nil)
            } catch { completionHandler(error) }
        }
    }
}
