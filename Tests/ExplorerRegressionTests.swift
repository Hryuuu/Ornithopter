import AppKit
import Foundation
import SwiftUI

@main
struct ExplorerRegressionTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() {
        var finished = false
        var failure: Error?
        Task { @MainActor in
            do { try await runChecks() }
            catch { failure = error }
            finished = true
        }
        // AppKit/NSItemProvider can stop a run-loop invocation. Keep pumping
        // until the async checks complete instead of exiting with status zero.
        while !finished {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        if let failure {
            fputs("FAIL: \(failure)\n", stderr)
            exit(1)
        }
    }

    static func runChecks() async throws {
        setbuf(stdout, nil)
        try testListingParser()
        try testLocalSFTP()
        testRequestVersions()
        testWidth()
        testDividerDrag()
        try await testStoreOrdering()
        try await testFailedRefresh()
        try await testLinks()
        try await testLinkConcurrency()
        try await testOutline()
        try await testInlineEditing()
        print("Checking file promises...")
        try await testFilePromises()
        print("PASS: \(checks) explorer regression checks")
    }

    static func testListingParser() throws {
        let names = ["a  b.txt", " leading.txt", "trailing.txt ", "한글.txt", "literal -> name.txt", "*star@=|", "quote'\".txt"]
        let lines = names.map { "-rw-r--r--    1 501 20 12 Sep 16 12:34 \($0)" }
        let listing = (["sftp> ls -an", "drwxr-xr-x    2 501 20 64 Sep 16 12:34 .", "drwxr-xr-x    2 501 20 64 Sep 16 12:34 ..", "drwxr-xr-x    2 501 20 64 Sep 16 12:34 folder.txt", "lrwxr-xr-x    1 501 20 8 Sep 16 2025 folder-link"] + lines + ["sftp> quit"]).joined(separator: "\n")
        let items = try RemoteDirectoryListing.parse(listing, basePath: "/root")
        expect(items.count == names.count + 2, "Every record is retained except dot entries")
        expect(items.first?.name == "folder.txt" && items.first?.isDirectory == true, "A directory with an extension remains a directory and sorts first")
        for name in names { expect(items.contains { $0.name == name && $0.path == "/root/" + name }, "Exact filename preservation: \(name)") }
        let link = items.first { $0.name == "folder-link" }!
        expect(link.kind == .symbolicLink && !link.isEditableFile, "Unresolved links must not be treated as files")
        var directoryLink = link
        directoryLink.linkTarget = .directory
        expect(directoryLink.isBrowsableDirectory && !directoryLink.isDirectory, "Browsable link remains a link for recursive deletion")
        expect(!AppPreferences.isTextEditableFile(items[0], patternsValue: "*"), "Directories are never sent to an editor")
        for invalid in ["plain-folder\nfile.txt", listing + "\nunparseable record", lines[0] + "\n" + lines[0]] {
            do { _ = try RemoteDirectoryListing.parse(invalid, basePath: "."); preconditionFailure("Invalid/duplicate records must fail, not silently become files") }
            catch { checks += 1 }
        }
        let bulk = (0..<10_000).map { "-rw-r--r--    1 501 20 0 Sep 16 12:34 file\($0).txt" }.joined(separator: "\n")
        let start = Date()
        let parsed = try RemoteDirectoryListing.parse(bulk, basePath: ".")
        expect(parsed.count == 10_000, "10,000 listing entries are not truncated")
        print("10,000-entry parse/sort: \(Date().timeIntervalSince(start)) seconds")
    }

    static func testLocalSFTP() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ornithopter-listing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["space  name.txt", " leading.txt", "trailing.txt ", "literal -> name.txt", "한글.txt"]
        for name in names { try Data().write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.txt"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("folder-link").path, withDestinationPath: "folder.txt")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = ["-D", "/usr/libexec/sftp-server", "-b", "-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("cd \"\(root.path)\"\nls -an\nquit\n".utf8))
        try input.fileHandleForWriting.close()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        expect(process.terminationStatus == 0, "Read-only local SFTP listing succeeds")
        let items = try RemoteDirectoryListing.parse(String(decoding: data, as: UTF8.self), basePath: ".")
        for name in names { expect(items.contains { $0.name == name }, "Actual OpenSSH output preserves \(name)") }
        expect(items.contains { $0.name == "folder.txt" && $0.isDirectory }, "Actual directory type")
        expect(items.contains { $0.name == "folder-link" && $0.kind == .symbolicLink }, "Actual link type")
    }

    static func testRequestVersions() {
        var requests = RemoteListingRequests()
        let old = requests.begin(path: "a")
        let new = requests.begin(path: "a")
        expect(!requests.finish(path: "a", request: old), "Out-of-order response rejected")
        expect(requests.finish(path: "a", request: new), "Latest response accepted")
        expect(requests.version(path: "a") == new, "Completed listing version remains available for link probes")
        requests.invalidateAll()
        expect(!requests.finish(path: "a", request: new), "Root refresh invalidates child responses")
        let child = requests.begin(path: "/folder/child")
        let sibling = requests.begin(path: "/folder-other")
        requests.invalidateSubtree("/folder")
        expect(!requests.finish(path: "/folder/child", request: child), "Subtree invalidation rejects descendants")
        expect(requests.finish(path: "/folder-other", request: sibling), "Subtree invalidation preserves siblings")
        requests.invalidateSubtree("/")
        expect(!requests.finish(path: "/folder-other", request: sibling), "Filesystem root invalidation rejects all absolute descendants")
    }

    static func testWidth() {
        expect(ExplorerWidth.clamped(240, availableWidth: 1120) == 240, "Default width")
        expect(ExplorerWidth.clamped(-20, availableWidth: 1120) == 180, "Explorer minimum")
        expect(ExplorerWidth.clamped(900, availableWidth: 920) == 294, "Terminal retains 620 points")
        expect(ExplorerWidth.clamped(.nan, availableWidth: 1120) == 240, "Corrupt stored width recovers")
    }

    static func testDividerDrag() {
        let divider = ExplorerResizeDivider.DividerView(frame: NSRect(x: 0, y: 0, width: 6, height: 100))
        divider.width = 240
        var values: [CGFloat] = []
        var saved: CGFloat = 0
        divider.onChange = { [weak divider] in values.append($0); divider?.width = $0 }
        divider.onEnd = { saved = $0 }
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 20), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        divider.mouseDown(with: event(.leftMouseDown, 100))
        divider.mouseDragged(with: event(.leftMouseDragged, 150))
        divider.mouseDragged(with: event(.leftMouseDragged, 160))
        divider.mouseUp(with: event(.leftMouseUp, 160))
        expect(values == [290, 300] && saved == 300, "Divider drag uses its initial width and persists only the final width")
    }

    nonisolated final class FailingRefreshLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func load(_ path: String) -> Result<[RemoteFileItem], Error> {
            lock.lock(); count += 1; let count = count; lock.unlock()
            if count == 1 { return .success([RemoteFileItem(name: "retained", path: "retained", isDirectory: true)]) }
            return .failure(RemoteDirectoryListing.InvalidListing())
        }
    }

    static func testFailedRefresh() async throws {
        let loader = FailingRefreshLoader()
        let store = RemoteFileStore(profile: ServerProfile(name: "fixture", host: "fixture.invalid", username: "fixture"), sessionPassword: nil, directoryLoader: { loader.load($0) })
        store.refresh()
        try await Task.sleep(for: .milliseconds(30))
        let original = store.items
        store.refresh()
        try await Task.sleep(for: .milliseconds(30))
        expect(store.items == original && store.items.first?.isDirectory == true, "Malformed refreshed listing preserves the last known types and items")
        expect(store.status.contains("Unable to read file types"), "Listing failure is reported instead of silently treating folders as files")
    }

    nonisolated final class OrderedLoader: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        func load(_ path: String) -> Result<[RemoteFileItem], Error> {
            lock.lock(); count += 1; let call = count; lock.unlock()
            Thread.sleep(forTimeInterval: call == 1 ? 0.15 : 0.01)
            return .success([RemoteFileItem(name: "\(call)", path: "\(call)", isDirectory: false)])
        }
    }

    static func testStoreOrdering() async throws {
        let loader = OrderedLoader()
        let profile = ServerProfile(name: "fixture", host: "fixture.invalid", username: "fixture")
        let store = RemoteFileStore(profile: profile, sessionPassword: nil, directoryLoader: { loader.load($0) })
        store.refresh()
        try await Task.sleep(for: .milliseconds(30))
        store.refresh()
        try await Task.sleep(for: .milliseconds(220))
        expect(store.items.first?.name == "2", "Late root response must not overwrite newer data")
        expect(store.loadingPaths.isEmpty, "Latest root completion clears loading state")
    }

    static func testLinks() async throws {
        let link = RemoteFileItem(name: "folder-link", path: "folder-link", kind: .symbolicLink)
        let store = RemoteFileStore(profile: ServerProfile(name: "fixture", host: "fixture.invalid", username: "fixture"), sessionPassword: nil,
                                    directoryLoader: { _ in .success([link]) }, linkProbe: { _ in .directory })
        store.refresh()
        try await Task.sleep(for: .milliseconds(30))
        store.resolveVisibleLink(link)
        try await Task.sleep(for: .milliseconds(30))
        expect(store.items[0].isBrowsableDirectory && !store.items[0].isDirectory, "Resolved folder link is navigable without changing actual type")
        expect(store.childrenByPath["."]?.first == store.items[0], "Root and child snapshots agree about resolved type")
    }

    nonisolated final class ProbeTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var count = 0
        private var maximum = 0
        var stats: (Int, Int) {
            lock.lock(); defer { lock.unlock() }
            return (count, maximum)
        }
        func probe(_ path: String) -> RemoteFileItem.LinkTarget {
            lock.lock(); active += 1; count += 1; maximum = max(maximum, active); lock.unlock()
            Thread.sleep(forTimeInterval: 0.02)
            lock.lock(); active -= 1; lock.unlock()
            return .directory
        }
    }

    static func testLinkConcurrency() async throws {
        let links = (0..<10).map { RemoteFileItem(name: "link\($0)", path: "link\($0)", kind: .symbolicLink) }
        let tracker = ProbeTracker()
        let store = RemoteFileStore(profile: ServerProfile(name: "fixture", host: "fixture.invalid", username: "fixture"), sessionPassword: nil,
                                    directoryLoader: { _ in .success(links) }, linkProbe: { tracker.probe($0) })
        store.refresh()
        try await Task.sleep(for: .milliseconds(30))
        for link in links { store.resolveVisibleLink(link); store.resolveVisibleLink(link) }
        try await Task.sleep(for: .milliseconds(180))
        expect(tracker.stats.0 == 10 && tracker.stats.1 == 2, "Link probes are deduplicated and bounded to two concurrent requests")
        for link in links { store.resolveVisibleLink(link) }
        try await Task.sleep(for: .milliseconds(30))
        expect(tracker.stats.0 == 10, "Stale visible-cell callbacks reuse resolved metadata")
        store.refresh()
        try await Task.sleep(for: .milliseconds(30))
        expect(store.items.allSatisfy(\.isBrowsableDirectory), "Refresh retains link presentation until new metadata arrives")
        for link in store.items { store.resolveVisibleLink(link) }
        try await Task.sleep(for: .milliseconds(180))
        expect(tracker.stats.0 == 20, "Explicit refresh revalidates cached link targets")
    }

    static func testFilePromises() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ornithopter-promise-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("promised.txt")
        try Data("promised content".utf8).write(to: source)
        let itemProvider = NSItemProvider()
        itemProvider.registerFileRepresentation(forTypeIdentifier: "public.data", fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        let token = UUID()
        let promise = RemoteFilePromiseProvider(provider: itemProvider, token: token, name: target.lastPathComponent, typeIdentifier: "public.data")
        expect(promise.filePromiseProvider(promise, fileNameForType: "public.data") == "promised.txt", "File promise retains the exact filename and extension")
        expect(promise.pasteboardPropertyList(forType: RemoteFilePromiseProvider.remoteType) as? String == token.uuidString, "Internal drag exposes only an opaque token")
        let error: Error? = await withCheckedContinuation { continuation in
            promise.filePromiseProvider(promise, writePromiseTo: target) { continuation.resume(returning: $0) }
        }
        expect(error == nil, "AppKit file promise is fulfilled successfully")
        let data = try Data(contentsOf: target)
        expect(data == Data("promised content".utf8), "Promised content reaches the supplied destination")
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func layout(_ view: NSView) { view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }

    static func click(_ outline: NSOutlineView, row: Int, count: Int, flags: NSEvent.ModifierFlags = [], timestamp: TimeInterval) {
        let rect = outline.rect(ofRow: row)
        let location = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let number = outline.window!.windowNumber
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: flags, timestamp: timestamp, windowNumber: number, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: flags, timestamp: timestamp + 0.01, windowNumber: number, context: nil, eventNumber: 2, clickCount: count, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
        if let event = NSApp.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true) {
            outline.mouseDown(with: event)
        }
    }

    final class InputTestWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    nonisolated final class EditingDirectoryLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var listings: [String: [RemoteFileItem]]
        private var delayChildListing = true
        let childListingReady = DispatchSemaphore(value: 0)

        init(_ listings: [String: [RemoteFileItem]]) { self.listings = listings }

        func setRoot(_ items: [RemoteFileItem]) {
            lock.lock(); defer { lock.unlock() }
            listings["."] = items
        }

        func load(_ path: String) -> Result<[RemoteFileItem], Error> {
            lock.lock()
            let items = listings[path] ?? []
            let shouldWait = path == "folder" && delayChildListing
            if shouldWait { delayChildListing = false }
            lock.unlock()
            if shouldWait { childListingReady.wait() }
            return .success(items)
        }
    }

    static func waitFor(_ message: String, condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        expect(condition(), message)
    }

    static func testInlineEditing() async throws {
        _ = NSApplication.shared
        let file = RemoteFileItem(name: "before.txt", path: "before.txt", isDirectory: false)
        let sibling = RemoteFileItem(name: "existing.txt", path: "existing.txt", isDirectory: false)
        let folder = RemoteFileItem(name: "folder", path: "folder", isDirectory: true)
        let child = RemoteFileItem(name: "child.txt", path: "folder/child.txt", isDirectory: false)
        let rootItems = [folder, file, sibling]
        let loader = EditingDirectoryLoader([".": rootItems, "folder": [child]])
        defer { loader.childListingReady.signal() }
        let store = RemoteFileStore(profile: ServerProfile(name: "fixture", host: "fixture.invalid", username: "fixture"), sessionPassword: nil,
                                    directoryLoader: { loader.load($0) })
        let view = RemoteFileOutlineView(store: store, availableProfiles: [], supportedTextFilePatterns: "*.txt", editAction: { _ in })
        let host = NSHostingView(rootView: view)
        let window = InputTestWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        store.refresh()
        try await waitFor("Initial editing fixture loads") { !store.items.isEmpty && store.loadingPaths.isEmpty }
        layout(host)
        guard let outline = descendants(host).compactMap({ $0 as? FileOutlineView }).first,
              let coordinator = outline.coordinator else { preconditionFailure("Editing fixture has an outline") }

        func row(for path: String) -> Int {
            (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? RemoteFileOutlineView.Node)?.path == path } ?? -1
        }
        func menu(_ title: String, at path: String? = nil) {
            let menu = coordinator.contextMenu(at: path.map { row(for: $0) } ?? -1)!
            let index = menu.items.firstIndex { $0.title == NSLocalizedString(title, comment: "") }!
            expect(menu.items[index].isEnabled, "Editing menu action is enabled: \(title)")
            menu.performActionForItem(at: index)
        }
        func editor() -> NSTextView {
            guard let node = coordinator.editingNode,
                  let cell = outline.view(atColumn: 0, row: outline.row(forItem: node), makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField, let editor = field.currentEditor() as? NSTextView else {
                preconditionFailure("Inline editing owns a field editor")
            }
            expect(field.isEditable && editor.isEditable && window.firstResponder === editor, "Inline field accepts keyboard input")
            return editor
        }
        func replaceName(_ value: String) {
            let editor = editor()
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            expect(editor.string == value, "Actual field editor accepts \(value)")
        }
        func command(_ selector: Selector) { editor().doCommand(by: selector) }
        func refresh(_ items: [RemoteFileItem]) async throws {
            loader.setRoot(items)
            store.refresh()
            try await waitFor("Refreshed editing fixture loads") { store.loadingPaths.isEmpty }
            layout(host)
            // Let the representable's deferred editor restoration run as well.
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
            layout(host)
        }

        menu("Rename...", at: file.path)
        expect(coordinator.editingNode?.path == file.path, "Rename stays active after the menu action")
        expect(editor().selectedRange() == NSRange(location: 0, length: "before".utf16.count), "Rename selects the basename without its extension")
        editor().insertText("새 이름 🪽", replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(editor().string == "새 이름 🪽.txt", "Typing replaces the selected basename and preserves the extension")
        command(#selector(NSResponder.cancelOperation(_:)))
        menu("Rename...", at: file.path)
        command(#selector(NSResponder.deleteBackward(_:)))
        expect(editor().string == ".txt", "Backspace deletes only the selected basename")
        replaceName("새 이름 🪽.txt")
        let selection = NSRange(location: 1, length: 2)
        editor().setSelectedRange(selection)
        coordinator.update(view)
        expect(editor().string == "새 이름 🪽.txt" && editor().selectedRange() == selection, "Ordinary updates preserve input and selection")

        let extra = RemoteFileItem(name: "added.txt", path: "added.txt", isDirectory: false)
        try await refresh([extra] + rootItems)
        expect(editor().string == "새 이름 🪽.txt" && editor().selectedRange() == selection, "Reloading and moving the edited row preserves its draft and selection")

        let staleField = NSTextField(string: "stale")
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: staleField))
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: staleField))
        expect(!coordinator.control(staleField, textView: editor(), doCommandBy: #selector(NSResponder.cancelOperation(_:))), "Commands from another field cannot cancel the current edit")
        expect(coordinator.editingNode?.path == file.path && editor().string == "새 이름 🪽.txt", "Stale field notifications leave the current edit intact")

        replaceName("")
        command(#selector(NSResponder.insertNewline(_:)))
        expect(coordinator.editingNode != nil && store.status == NSLocalizedString("Name cannot be empty.", comment: ""), "Enter with an empty name keeps editing and reports validation")
        replaceName(sibling.name)
        command(#selector(NSResponder.insertNewline(_:)))
        expect(coordinator.editingNode != nil && store.status.contains(sibling.name), "Enter with a duplicate name keeps editing")
        replaceName(file.name)
        command(#selector(NSResponder.insertNewline(_:)))
        expect(coordinator.editingNode == nil && window.firstResponder === outline, "Enter with an unchanged name completes editing without a remote request")

        menu("Rename...", at: file.path)
        replaceName("cancelled.txt")
        command(#selector(NSResponder.cancelOperation(_:)))
        let restoredField = (outline.view(atColumn: 0, row: row(for: file.path), makeIfNecessary: true) as? NSTableCellView)?.textField
        expect(coordinator.editingNode == nil && restoredField?.stringValue == file.name, "Escape restores the original filename")

        menu("New Folder...")
        try await waitFor("New folder starts editing") { coordinator.editingNode?.newFolderParent == "." }
        expect(store.newFolderParent == "." && outline.numberOfRows == 5, "New folder placeholder survives opening the editor")
        replaceName("새 폴더 🪽")
        editor().setSelectedRange(selection)
        try await refresh(rootItems)
        expect(store.newFolderParent == "." && editor().string == "새 폴더 🪽" && editor().selectedRange() == selection, "New folder draft and selection survive a root reload")
        replaceName("")
        command(#selector(NSResponder.insertNewline(_:)))
        expect(store.newFolderParent == "." && coordinator.editingNode != nil, "Invalid folder name does not remove its input row")
        replaceName(sibling.name)
        command(#selector(NSResponder.insertNewline(_:)))
        expect(store.newFolderParent == "." && coordinator.editingNode != nil, "Duplicate folder name remains editable")
        command(#selector(NSResponder.cancelOperation(_:)))
        expect(store.newFolderParent == nil && coordinator.editingNode == nil, "Escape removes the uncommitted folder")
        coordinator.update(view)

        menu("New Folder...", at: folder.path)
        try await waitFor("Nested placeholder starts editing before its listing arrives") { coordinator.editingNode?.newFolderParent == folder.path }
        replaceName("하위 폴더")
        editor().setSelectedRange(selection)
        loader.childListingReady.signal()
        try await waitFor("Delayed child listing completes") { store.loadingPaths.isEmpty }
        layout(host)
        try await Task.sleep(for: .milliseconds(20))
        expect(editor().string == "하위 폴더" && editor().selectedRange() == selection, "Delayed child listing preserves the nested folder draft")
        // A real focus transfer still means cancellation, unlike internal reloads.
        window.makeFirstResponder(outline)
        expect(coordinator.editingNode == nil && store.newFolderParent == nil, "Leaving the folder field cancels the draft")
        coordinator.update(view)

        menu("Rename...", at: file.path)
        replaceName("removed.txt")
        let removedField = (outline.view(atColumn: 0, row: row(for: file.path), makeIfNecessary: true) as? NSTableCellView)?.textField
        try await refresh([folder, sibling])
        expect(coordinator.editingNode == nil && removedField?.isEditable == false && removedField?.currentEditor() == nil, "Removing the edited item ends and disables its editing session")

        for (name, isDirectory, selectedName) in [
            ("README", false, "README"),
            (".env", false, ".env"),
            (".env.local", false, ".env"),
            ("archive.tar.gz", false, "archive.tar"),
            ("한글 🪽.txt", false, "한글 🪽"),
            ("release.1", true, "release.1")
        ] {
            let item = RemoteFileItem(name: name, path: name, isDirectory: isDirectory)
            try await refresh([item])
            menu("Rename...", at: item.path)
            expect(editor().selectedRange() == NSRange(location: 0, length: selectedName.utf16.count), "Initial rename selection respects file type and Unicode: \(name)")
            command(#selector(NSResponder.cancelOperation(_:)))
        }
        print("Inline editing: focus, text input, validation, cancellation, and reload checks passed")
    }

    static func testOutline() async throws {
        _ = NSApplication.shared
        let folder = RemoteFileItem(name: "many", path: "many", isDirectory: true)
        let children = (0..<10_000).map { RemoteFileItem(name: "file\($0).txt", path: "many/file\($0).txt", isDirectory: false) }
        let store = RemoteFileStore(profile: ServerProfile(name: "fixture", host: "fixture.invalid", username: "fixture"), sessionPassword: nil,
                                    directoryLoader: { path in .success(path == "." ? [folder] : children) })
        var opened: [String] = []
        let host = NSHostingView(rootView: RemoteFileOutlineView(store: store, availableProfiles: [], supportedTextFilePatterns: "*.txt", editAction: { opened.append($0.path) }))
        let window = InputTestWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        store.refresh()
        try await Task.sleep(for: .milliseconds(80))
        layout(host)
        guard let outline = descendants(host).compactMap({ $0 as? FileOutlineView }).first else { preconditionFailure("Native outline exists") }
        expect(outline.numberOfRows == 1, "Initial tree has one folder")
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        expect(!store.isExpanded(folder) && opened.isEmpty, "Selection alone neither expands nor opens")
        let start = Date()
        outline.coordinator?.activate(folder)
        try await Task.sleep(for: .milliseconds(100))
        layout(host)
        expect(outline.numberOfRows == 10_001, "Expanded 10,000-child folder has all rows")
        var available = 0
        outline.enumerateAvailableRowViews { _, _ in available += 1 }
        expect(available < 100, "Only viewport cells are materialized, not 10,000 recursive SwiftUI rows")
        expect(Date().timeIntervalSince(start) < 1, "Expansion and layout complete within one second")
        print("10,000-child native outline: \(available) materialized rows, \(Date().timeIntervalSince(start)) seconds")
        outline.selectRowIndexes(IndexSet(integersIn: 1..<5), byExtendingSelection: false)
        expect(store.selectedPaths.count == 4 && opened.isEmpty, "Native range selection updates store without activation")
        outline.coordinator?.activate(children[0])
        expect(opened == [children[0].path], "File activation opens exactly one editor")
        outline.coordinator?.activate(folder)
        try await Task.sleep(for: .milliseconds(30))
        layout(host)
        expect(outline.numberOfRows == 1, "Second folder activation collapses")
        expect(opened.count == 1, "Folder activation never opens a terminal")
        try await Task.sleep(for: .milliseconds(30))
        expect(store.selectedPaths.isEmpty, "Collapsing a parent removes hidden selection")
        store.open(folder)
        try await Task.sleep(for: .milliseconds(30))
        layout(host)
        outline.selectRowIndexes(IndexSet(integersIn: 1..<4), byExtendingSelection: false)
        _ = outline.coordinator?.contextMenu(at: 2)
        expect(store.selectedPaths.count == 3, "Right-click inside selection preserves the group")
        _ = outline.coordinator?.contextMenu(at: 5)
        expect(store.selectedPaths == [children[4].path], "Right-click outside selection targets only the clicked item")
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        window.makeKey()
        try await Task.sleep(for: .milliseconds(50))
        let timestamp = ProcessInfo.processInfo.systemUptime
        let before = opened.count
        click(outline, row: 1, count: 1, timestamp: timestamp)
        click(outline, row: 1, count: 1, timestamp: timestamp + NSEvent.doubleClickInterval + 1)
        expect(opened.count == before, "Separated single clicks never activate the selected file")
        click(outline, row: 1, count: 2, timestamp: timestamp + NSEvent.doubleClickInterval + 1.1)
        expect(opened.count == before + 1, "Native double-click opens a file exactly once")
        click(outline, row: 1, count: 2, flags: .command, timestamp: timestamp + 3)
        expect(opened.count == before + 1, "Modified double-click only changes selection")
        if let imagePath = ProcessInfo.processInfo.environment["ORNITHOPTER_TEST_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: imagePath))
        }
        window.orderOut(nil)
        window.contentView = nil
    }
}
