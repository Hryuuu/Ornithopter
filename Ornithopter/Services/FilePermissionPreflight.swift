import Foundation

nonisolated enum FilePermissionPreflight {
    enum Access: String { case read, write, delete, move, directory }
    struct Request {
        let path: String
        let access: Access
    }
    struct Issue {
        let path: String
        let reason: String
    }
    enum Outcome {
        case allowed
        case denied([Issue])
        case unavailable
    }

    // NUL-delimited records preserve spaces, newlines and shell metacharacters
    // in paths. Checks run as the authenticated account, including its ACLs.
    static func remoteCommand(_ requests: [Request]) -> String {
        let checker = #"""
        report() { printf '%s\000%s\000' "$1" "$2"; }
        check() {
            p=$1
            case "$mode" in
                read)
                    if [ ! -r "$p" ]; then report read "$p"; fi
                    if [ -d "$p" ] && [ ! -x "$p" ]; then report search "$p"; fi
                    ;;
                directory)
                    if [ ! -d "$p" ] || [ ! -w "$p" ] || [ ! -x "$p" ]; then report write "$p"; fi
                    ;;
                write)
                    if [ -e "$p" ] || [ -L "$p" ]; then
                        if [ ! -w "$p" ]; then report write "$p"; fi
                        if [ -d "$p" ] && [ ! -x "$p" ]; then report search "$p"; fi
                    else
                        parent=$(dirname "$p") || exit 78
                        while [ ! -e "$parent" ]; do
                            next=$(dirname "$parent") || exit 78
                            [ "$next" != "$parent" ] || exit 78
                            parent=$next
                        done
                        if [ ! -d "$parent" ] || [ ! -w "$parent" ] || [ ! -x "$parent" ]; then report write "$parent"; fi
                    fi
                    ;;
                delete|move)
                    parent=$(dirname "$p") || exit 78
                    if [ ! -w "$parent" ] || [ ! -x "$parent" ]; then report delete "$p"; fi
                    if [ -k "$parent" ] && [ "$uid" != 0 ] && [ ! -O "$parent" ] && [ -z "$(find "$p" -prune -user "$uid" -print 2>/dev/null)" ]; then report sticky "$p"; fi
                    if [ "$mode" = delete ] && [ -d "$p" ] && [ ! -L "$p" ]; then
                        if [ ! -r "$p" ] || [ ! -x "$p" ]; then report search "$p"; fi
                    fi
                    ;;
            esac
        }
        mode=$1; uid=$2; shift 2
        for p do check "$p"; done
        """#
        let quotedChecker = SSHCommandBuilder.shellQuotedArgument(checker)
        var lines = ["LC_ALL=C; export LC_ALL", "checker=\(quotedChecker)", "uid=$(id -u) || exit 78", "printf 'ORNITHOPTER_PERMISSIONS_V1\\000'"]
        for request in requests {
            let path = request.path == "~" || request.path.hasPrefix("/") || request.path.hasPrefix("~/") ? request.path : "./" + request.path
            let quotedPath = SSHCommandBuilder.shellQuotedArgument(path)
            let arguments = "\(request.access.rawValue) \"$uid\""
            lines.append("sh -c \"$checker\" sh \(arguments) \(quotedPath) || exit 78")
            if request.access != .directory && request.access != .move {
                let follow = request.access == .delete ? "" : "-L "
                lines.append("if [ -d \(quotedPath) ] && \(request.access == .delete ? "[ ! -L \(quotedPath) ]" : "true"); then find \(follow)\(quotedPath) -exec sh -c \"$checker\" sh \(arguments) {} + || exit 78; fi")
            }
        }
        lines.append("printf 'END\\000'")
        return lines.joined(separator: "\n")
    }

    static func parseRemoteOutput(_ output: String, status: Int32) -> Outcome {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard fields.first == "ORNITHOPTER_PERMISSIONS_V1" else { return .unavailable }
        let complete = fields.count >= 3 && fields.suffix(2) == ["END", ""] && status == 0
        let end = complete ? fields.count - 2 : fields.count - 1
        var issues: [Issue] = []
        var index = 1
        let reasons = ["read": "Read permission is required", "write": "Write permission is required", "search": "Folder access permission is required", "delete": "Parent folder write and access permissions are required", "sticky": "Only the owner may delete this item"]
        while index + 1 < end {
            guard let reason = reasons[fields[index]] else { return .unavailable }
            let issue = Issue(path: fields[index + 1], reason: NSLocalizedString(reason, comment: ""))
            if !issues.contains(where: { $0.path == issue.path && $0.reason == issue.reason }) { issues.append(issue) }
            index += 2
        }
        if !issues.isEmpty { return .denied(issues) }
        return complete && index == end ? .allowed : .unavailable
    }

    static func localReadIssues(_ urls: [URL]) -> [Issue] {
        var issues: [Issue] = []
        let manager = FileManager.default
        func check(_ url: URL) {
            var directory: ObjCBool = false
            let exists = manager.fileExists(atPath: url.path, isDirectory: &directory)
            if !exists || !manager.isReadableFile(atPath: url.path) || (directory.boolValue && !manager.isExecutableFile(atPath: url.path)) {
                issues.append(Issue(path: url.path, reason: NSLocalizedString("Read and folder access permissions are required", comment: "")))
            }
        }
        for url in urls {
            check(url)
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], errorHandler: { url, _ in
                issues.append(Issue(path: url.path, reason: NSLocalizedString("Unable to inspect this folder", comment: "")))
                return true
            }) else {
                issues.append(Issue(path: url.path, reason: NSLocalizedString("Unable to inspect this folder", comment: "")))
                continue
            }
            for case let child as URL in enumerator { check(child) }
        }
        return issues
    }

    static func localWriteIssues(_ urls: [URL]) -> [Issue] {
        let manager = FileManager.default
        var issues: [Issue] = []
        for url in urls {
            var existing = url
            while !manager.fileExists(atPath: existing.path), existing.path != "/" {
                existing.deleteLastPathComponent()
            }
            var directory: ObjCBool = false
            _ = manager.fileExists(atPath: existing.path, isDirectory: &directory)
            if (existing.path != url.path && !directory.boolValue) || !manager.isWritableFile(atPath: existing.path) || (directory.boolValue && !manager.isExecutableFile(atPath: existing.path)) {
                issues.append(Issue(path: existing.path, reason: NSLocalizedString("Write and folder access permissions are required", comment: "")))
            }
        }
        return issues
    }

    static func message(_ issues: [Issue]) -> String {
        let details = issues.prefix(12).map { "\($0.path): \($0.reason)" }.joined(separator: "\n")
        let remainder = issues.count > 12 ? "\n" + String(format: NSLocalizedString("And %d more items", comment: ""), issues.count - 12) : ""
        return NSLocalizedString("Permission check failed. No files were changed.", comment: "") + "\n\n" + details + remainder
    }
}
