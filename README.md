# Ornithopter

Ornithopter is a macOS SwiftUI app for managing SSH connection profiles and launching common SSH/SCP workflows from one place.

## Current Scope

- Store SSH profiles locally with host, username, port, identity file, remote path, tags, and notes.
- Search and edit saved profiles in a split-view macOS interface.
- Generate `ssh` and `scp` commands.
- Open generated commands in Terminal.app or copy them to the clipboard.

Passwords are intentionally not stored. Prefer SSH keys and macOS Keychain for future credential-related features.

## Development Notes

- The app is a standard Xcode SwiftUI macOS project.
- Source files live in `Ornithopter/`.
- The Xcode project uses a synchronized root group, so new Swift files in `Ornithopter/` are picked up by the target.
- CLI type checking can be run with:

```sh
swiftc -module-cache-path /private/tmp/ornithopter-module-cache -typecheck Ornithopter/*.swift
```

Full `xcodebuild` verification requires selecting an installed Xcode developer directory, not Command Line Tools.
