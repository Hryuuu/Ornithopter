# Security Policy

## SSH Password Handling

Ornithopter supports password authentication for SSH and SFTP sessions. Passwords are only stored when the user explicitly enables Keychain saving for a server profile.

- New server profiles do not enable password saving by default.
- Saved SSH passwords are stored in macOS Keychain as generic password items.
- Keychain items are marked as available only while the device is unlocked and are not migratable to other devices.
- Ornithopter does not store SSH passwords in server profile data.
- Ornithopter does not pass SSH passwords through child process environment variables.
- Passwords are supplied to OpenSSH through a per-session askpass helper in a private temporary directory and are cleaned up when the session or operation ends.
- The Settings window provides an option to remove all SSH passwords saved by Ornithopter from macOS Keychain.

## Reporting Security Issues

Please report security issues privately through GitHub's security advisory feature when available. If that is not available, open a minimal issue asking for a private contact path and do not include exploit details or sensitive information in the public issue.
