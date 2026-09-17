import Foundation

nonisolated struct RemoteFileItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case file, directory, symbolicLink, other }
    enum LinkTarget: Sendable { case unresolved, directory, nonDirectory, unavailable }

    let name: String
    let path: String
    let kind: Kind
    var linkTarget: LinkTarget = .unresolved

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.kind = isDirectory ? .directory : .file
    }

    init(name: String, path: String, kind: Kind, linkTarget: LinkTarget = .unresolved) {
        self.name = name
        self.path = path
        self.kind = kind
        self.linkTarget = linkTarget
    }

    var id: String { path }
    // File operations must distinguish a directory from a link to one.
    var isDirectory: Bool { kind == .directory }
    var isBrowsableDirectory: Bool { isDirectory || (kind == .symbolicLink && linkTarget == .directory) }
    var isEditableFile: Bool { kind == .file || (kind == .symbolicLink && linkTarget == .nonDirectory) }
    var isHidden: Bool { name.hasPrefix(".") }
}

nonisolated enum RemoteDirectoryListing {
    struct InvalidListing: LocalizedError {
        var errorDescription: String? {
            NSLocalizedString("Unable to read file types from the directory listing.", comment: "")
        }
    }

    // Consume the metadata, then preserve the filename verbatim (including spaces).
    private static let longLine = try! NSRegularExpression(
        pattern: #"^([bcdlps-][rwxstST-]{9}[+@.]?)[ \t]+(?:\S+[ \t]+){6}\S+[ \t](.*)$"#
    )

    static func parse(_ output: String, basePath: String) throws -> [RemoteFileItem] {
        var items: [RemoteFileItem] = []
        var paths: Set<String> = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("sftp>") || line.hasPrefix("Connected to ") { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = longLine.firstMatch(in: line, range: range),
                  let modeRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line) else {
                throw InvalidListing()
            }
            let name = String(line[nameRange])
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { throw InvalidListing() }
            let kind: RemoteFileItem.Kind
            switch line[modeRange].first {
            case "d": kind = .directory
            case "l": kind = .symbolicLink
            case "-": kind = .file
            default: kind = .other
            }
            let path = basePath == "/" ? "/" + name : (basePath == "." || basePath.isEmpty ? name : basePath + "/" + name)
            guard paths.insert(path).inserted else { throw InvalidListing() }
            items.append(RemoteFileItem(name: name, path: path, kind: kind))
        }
        return items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
