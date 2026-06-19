# Ornithopter

Ornithopter is a simple, free SSH client for macOS, built to provide a lightweight terminal-focused workflow with X11 forwarding support.

The goal is to make it easy to keep SSH connections in one place, open remote terminals quickly, and work with remote files without leaving the app.

## Features

- Manage SSH server profiles with host, username, port, notes, and tags.
- Connect with password authentication, SSH key files, or stored Keychain passwords.
- Open integrated SSH terminal sessions inside the app using SwiftTerm.
- Use multiple terminal tabs for the same server.
- Split the terminal area horizontally or vertically.
- Enable X11 forwarding with `-X` or trusted `-Y` mode per server. Requires XQuartz.
- Browse remote files over SFTP.
- Create, rename, delete, copy, paste, upload, and download remote files and folders.
- Hide or show dotfiles in the remote file browser.
- Open supported text files in a new terminal tab with a configurable terminal editor.
- Configure default editor, editable file patterns, and default SSH key file.

## Notes

- Server profiles are stored locally on the user's Mac.
- Passwords are stored in macOS Keychain when the save-password option is enabled.

## Attribution

This project was written with Codex and reviewed by the hryu.
