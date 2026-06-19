//
//  OrnithopterApp.swift
//  Ornithopter
//
//  Created by 류한서 on 6/18/26.
//

import SwiftUI

@main
struct OrnithopterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 820, height: 750)

        Settings {
            OrnithopterSettingsView()
        }
    }
}

enum AppPreferenceDefaults {
    static let textEditor = "vi"
    static let customTextEditor = ""
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
        guard !item.isDirectory else {
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

private struct OrnithopterSettingsView: View {
    @AppStorage("defaultTextEditor") private var defaultTextEditor = AppPreferenceDefaults.textEditor
    @AppStorage("customTextEditor") private var customTextEditor = AppPreferenceDefaults.customTextEditor
    @AppStorage("supportedTextFilePatterns") private var supportedTextFilePatterns = AppPreferenceDefaults.supportedTextFilePatterns

    var body: some View {
        Form {
            Section {
                Picker("Default text editor", selection: $defaultTextEditor) {
                    Text("vi").tag("vi")
                    Text("vim").tag("vim")
                    Text("nano").tag("nano")
                    Text("emacs").tag("emacs")
                    Text("micro").tag("micro")
                    Text("Custom...").tag("custom")
                }
                .pickerStyle(.menu)

                if defaultTextEditor == "custom" {
                    TextField("Editor command", text: $customTextEditor)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section {
                TextEditor(text: $supportedTextFilePatterns)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                Text("Use comma-separated patterns, such as *.txt, *.md, *.py.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Supported file formats")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 380)
    }
}
