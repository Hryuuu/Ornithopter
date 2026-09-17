import Foundation

enum AppPreferenceDefaults {
    static let textEditor = "vi"
    static let customTextEditor = ""
    static let defaultIdentityFile = ""
    static let autoCloseTerminalTabOnNormalExit = true
    static let supportedTextFilePatterns = [
        "*.txt",
        "*.md",
        "*.markdown",
        "*.c",
        "*.h",
        "*.cc",
        "*.cpp",
        "*.cxx",
        "*.hpp",
        "*.py",
        "*.sh",
        "*.bash",
        "*.zsh",
        "*.swift",
        "*.js",
        "*.ts",
        "*.json",
        "*.yaml",
        "*.yml",
        "*.toml",
        "*.xml",
        "*.html",
        "*.css",
        "*.java",
        "*.kt",
        "*.rs",
        "*.go",
        "*.rb",
        "*.php",
        "*.pl",
        "*.r",
        "*.lua",
        "*.sql",
        "*.csv",
        "*.tex"
    ].joined(separator: ", ")
}

enum AppPreferences {
    static func effectiveTextEditor(defaultEditor: String, customEditor: String) -> String {
        if defaultEditor == "custom" {
            let trimmed = customEditor.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? AppPreferenceDefaults.textEditor : trimmed
        }

        return defaultEditor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppPreferenceDefaults.textEditor
            : defaultEditor
    }

    static func supportedFilePatterns(from value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",\n\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func isTextEditableFile(_ item: RemoteFileItem, patternsValue: String) -> Bool {
        guard item.isEditableFile else {
            return false
        }

        let patterns = supportedFilePatterns(from: patternsValue)
        guard !patterns.isEmpty else {
            return false
        }

        let name = item.name.lowercased()
        let pathExtension = (item.name as NSString).pathExtension.lowercased()

        return patterns.contains { pattern in
            if pattern == "*" || pattern == "*.*" {
                return true
            }

            if pattern.hasPrefix("*.") {
                return pathExtension == String(pattern.dropFirst(2))
            }

            return name == pattern
        }
    }
}

