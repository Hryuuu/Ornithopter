import AppKit
import Darwin
import Foundation

@main
struct RegressionTests {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (Int32, String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ornithopter-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try testPipes()
        try testProcessOutput()
        try testAskpass()
        try testPermissions(root)
        try testSFTPArguments(root)
        try testSFTPFailure(root)
        try testFirstConnection(root)
        testInputRouting()
        print("PASS: \(checks) regression checks")
    }

    static func testPipes() throws {
        signal(SIGPIPE, SIG_DFL)
        for _ in 0..<100 {
            var fds: [Int32] = [0, 0]
            expect(pipe(&fds) == 0, "pipe creation")
            close(fds[0])
            do {
                try ProcessPipeWriter.write(Data("secret\n".utf8), to: fds[1])
                preconditionFailure("Writing to a closed pipe must fail")
            } catch let error as POSIXError {
                expect(error.code == .EPIPE, "Closed pipe must report EPIPE without terminating the app")
            }
            close(fds[1])
        }
        let pipe = Pipe()
        do {
            try ProcessPipeWriter.write(Data(repeating: 0, count: 1_000_000), to: pipe.fileHandleForWriting.fileDescriptor, timeout: 0.05)
            preconditionFailure("Blocked pipe must time out")
        } catch let error as POSIXError {
            expect(error.code == .ETIMEDOUT, "Bounded pipe write")
        }
    }

    static func testAskpass() throws {
        let hostPrompt = "The authenticity of host 'test.invalid (127.0.0.1)' can't be established.\nED25519 key fingerprint is SHA256:EXAMPLE.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "
        expect(SSHAuthenticationPrompt.classify(hostPrompt, hint: "") == .hostKey, "First connection must request host verification")
        expect(SSHAuthenticationPrompt.classify("test@test.invalid's password: ", hint: "") == .password, "Password prompt classification")
        expect(SSHAuthenticationPrompt.classify("Enter passphrase for key '/tmp/key':", hint: "") == .secret, "Key passphrase must not receive server password")
        expect(SSHAuthenticationPrompt.classify("Allow access?", hint: "confirm") == .confirmation, "Confirmation is not a password request")

        for response in ["yes", "no"] {
            let session = SSHAskPassSession(password: "not-the-fingerprint-answer", promptResponse: { _, _ in response })!
            let result = try run(session.environment["SSH_ASKPASS"]!, [hostPrompt], environment: session.environment)
            expect(result.0 == 0 && result.1 == response + "\n", "Host confirmation response must be explicit")
            session.stop()
            expect(!FileManager.default.fileExists(atPath: session.environment["SSH_ASKPASS"]!), "Askpass cleanup")
        }
        let session = SSHAskPassSession(password: "test-password")!
        defer { session.stop() }
        for _ in 0..<10 {
            let result = try run(session.environment["SSH_ASKPASS"]!, ["test@test.invalid's password:"], environment: session.environment)
            expect(result.1 == "test-password\n", "Each prompt must receive exactly one password")
        }
        var notificationEnvironment = session.environment
        notificationEnvironment["SSH_ASKPASS_PROMPT"] = "none"
        let notification = try run(session.environment["SSH_ASKPASS"]!, ["Touch your security key"], environment: notificationEnvironment)
        expect(notification.0 == 0 && notification.1.isEmpty, "Notifications must not consume a password")
    }

    static func testProcessOutput() throws {
        for _ in 0..<30 {
            let process = Process()
            let output = Pipe(), error = Pipe()
            let out = ProcessOutputCollector(), err = ProcessOutputCollector()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "i=0; while [ $i -lt 2000 ]; do printf 'stdout\\n'; printf 'stderr\\n' >&2; i=$((i+1)); done"]
            process.standardOutput = output; process.standardError = error
            try process.run()
            try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
            try out.start(readingFrom: output.fileHandleForReading)
            try err.start(readingFrom: error.fileHandleForReading)
            process.waitUntilExit()
            expect(try out.finish(readingFrom: output.fileHandleForReading) == String(repeating: "stdout\n", count: 2000), "Process stdout must be drained once without loss")
            expect(try err.finish(readingFrom: error.fileHandleForReading) == String(repeating: "stderr\n", count: 2000), "Process stderr must be drained once without loss")
            out.stop(readingFrom: output.fileHandleForReading)
            err.stop(readingFrom: error.fileHandleForReading)
        }
        let pipe = Pipe()
        let collector = ProcessOutputCollector()
        try collector.start(readingFrom: pipe.fileHandleForReading)
        collector.stop(readingFrom: pipe.fileHandleForReading)
        expect(try collector.finish(readingFrom: pipe.fileHandleForReading).isEmpty, "Cancelled reader can be finished safely")
    }

    static func testPermissions(_ root: URL) throws {
        let file = root.appendingPathComponent("space ' quote $()\nfile")
        try Data("unchanged".utf8).write(to: file)
        func outcome(_ requests: [FilePermissionPreflight.Request]) throws -> FilePermissionPreflight.Outcome {
            let result = try run("/bin/sh", ["-c", FilePermissionPreflight.remoteCommand(requests)])
            return FilePermissionPreflight.parseRemoteOutput(result.1, status: result.0)
        }
        func allowed(_ outcome: FilePermissionPreflight.Outcome) -> Bool {
            if case .allowed = outcome { return true }; return false
        }
        func denied(_ outcome: FilePermissionPreflight.Outcome, path: String) -> Bool {
            if case .denied(let issues) = outcome { return issues.contains { $0.path == path } }; return false
        }
        expect(allowed(try outcome([.init(path: file.path, access: .read)])), "Readable paths with shell metacharacters")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        expect(denied(try outcome([.init(path: root.path, access: .read)]), path: file.path), "Recursive read detects inaccessible child")
        expect(!FilePermissionPreflight.localReadIssues([root]).isEmpty, "Local recursive read check")
        expect(allowed(try outcome([.init(path: file.path, access: .delete)])), "Deletion does not require file write permission")
        expect(allowed(try outcome([.init(path: file.path, access: .move)])), "Moving an unreadable file requires parent access, not file read permission")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        expect(denied(try outcome([.init(path: file.path, access: .delete)]), path: file.path), "Deletion requires parent write permission")
        expect(!FilePermissionPreflight.localWriteIssues([root.appendingPathComponent("new")]).isEmpty, "Local destination permission check")
        expect(denied(try outcome([.init(path: root.path, access: .directory)]), path: root.path), "Upload destination requires write permission")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        expect(try Data(contentsOf: file) == Data("unchanged".utf8), "Preflight must not mutate files")
        expect(!FilePermissionPreflight.localWriteIssues([file.appendingPathComponent("child")]).isEmpty, "A regular file cannot serve as a destination parent")
        expect(allowed(try outcome([.init(path: root.appendingPathComponent("new/child").path, access: .write)])), "New destination checks nearest existing parent")
        if case .unavailable = FilePermissionPreflight.parseRemoteOutput("SFTP only", status: 1) { checks += 1 } else { preconditionFailure("Restricted shell is unknown, not allowed") }
        if case .unavailable = FilePermissionPreflight.parseRemoteOutput("ORNITHOPTER_PERMISSIONS_V1\0", status: 1) { checks += 1 } else { preconditionFailure("Incomplete scan is unknown") }
    }

    static func testSFTPArguments(_ root: URL) throws {
        let helper = root.appendingPathComponent("ssh-arguments.sh")
        let captured = root.appendingPathComponent("ssh-arguments")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE_ARGUMENTS\"\nexit 1\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        for password in [true, false] {
            let profile = ServerProfile(name: "test", host: "test.invalid", username: "test", passwordAuthentication: password)
            let arguments = ["-S", helper.path] + SSHCommandBuilder.sftpArguments(for: profile, allowPassword: password)
            _ = try run("/usr/bin/sftp", arguments, environment: ["CAPTURE_ARGUMENTS": captured.path])
            let sshArguments = try String(contentsOf: captured, encoding: .utf8).lowercased()
            let firstBatchMode = sshArguments.range(of: "batchmode")!
            expect(sshArguments[firstBatchMode.lowerBound...].hasPrefix("batchmode=no"), "Askpass must remain enabled before sftp adds BatchMode=yes")
            expect(arguments.contains("-b"), "Both authentication methods must stop on SFTP command failure")
        }
    }

    static func testFirstConnection(_ root: URL) throws {
        let hostKey = root.appendingPathComponent("host_key")
        let knownHosts = root.appendingPathComponent("known_hosts")
        let config = root.appendingPathComponent("sshd_config")
        expect(try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path]).0 == 0, "Fixture host key")
        try "HostKey \(hostKey.path)\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication no\nLogLevel ERROR\n".write(to: config, atomically: true, encoding: .utf8)
        let arguments = ["-F", "/dev/null", "-o", "ProxyCommand=/usr/sbin/sshd -i -f \(SSHCommandBuilder.shellQuotedArgument(config.path))", "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=ask", "-o", "PreferredAuthentications=none", "-o", "ConnectTimeout=5", "fixture.invalid", "exit"]
        for answer in ["no", "yes"] {
            let session = SSHAskPassSession(password: "must-not-be-used", promptResponse: { prompt, hint in
                guard SSHAuthenticationPrompt.classify(prompt, hint: hint) == .hostKey else { return "no" }
                return answer
            })!
            var environment = SSHProcessEnvironment.baseEnvironment()
            environment.merge(session.environment) { _, new in new }
            let result = try run("/usr/bin/ssh", arguments, environment: environment)
            session.stop()
            expect(result.0 == 255, "Fixture denies authentication after host verification")
            expect(FileManager.default.fileExists(atPath: knownHosts.path) == (answer == "yes"), "Only explicit host approval may persist a fingerprint")
        }
        let saved = try Data(contentsOf: knownHosts)
        let repeated = SSHAskPassSession(password: nil, promptResponse: { _, _ in preconditionFailure("Known host must not prompt again") })!
        var environment = SSHProcessEnvironment.baseEnvironment()
        environment.merge(repeated.environment) { _, new in new }
        _ = try run("/usr/bin/ssh", arguments, environment: environment)
        repeated.stop()
        expect(try Data(contentsOf: knownHosts) == saved, "Reconnect preserves accepted fingerprint")
        let changedKey = root.appendingPathComponent("changed_host_key")
        expect(try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", changedKey.path]).0 == 0, "Replacement fixture key")
        var serverConfig = try String(contentsOf: config, encoding: .utf8)
        serverConfig = serverConfig.replacingOccurrences(of: hostKey.path, with: changedKey.path)
        try serverConfig.write(to: config, atomically: true, encoding: .utf8)
        let changed = SSHAskPassSession(password: nil, promptResponse: { _, _ in preconditionFailure("Changed host key must not be approved") })!
        environment.merge(changed.environment) { _, new in new }
        expect(try run("/usr/bin/ssh", arguments, environment: environment).0 == 255, "Changed fingerprint is rejected")
        changed.stop()
        expect(try Data(contentsOf: knownHosts) == saved, "Changed fingerprint must not overwrite trusted key")
    }

    static func testSFTPFailure(_ root: URL) throws {
        let folder = root.appendingPathComponent("protected")
        let file = folder.appendingPathComponent("keep")
        let later = root.appendingPathComponent("must-not-run")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = ["-D", "/usr/libexec/sftp-server", "-b", "-"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        try ProcessPipeWriter.write(Data("rm \"\(file.path)\"\nmkdir \"\(later.path)\"\nquit\n".utf8), to: input.fileHandleForWriting.fileDescriptor)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        expect(process.terminationStatus != 0, "SFTP permission failure must not report success")
        expect(FileManager.default.fileExists(atPath: file.path), "Permission-denied file is retained")
        expect(!FileManager.default.fileExists(atPath: later.path), "SFTP batch stops before the next mutation")
    }

    @MainActor final class TestWindow: NSWindow {
        var key = false
        override var isKeyWindow: Bool { key }
    }
    @MainActor final class TestView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    static func testInputRouting() {
        _ = NSApplication.shared
        let first = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        let second = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        let a = TestView(), b = TestView()
        first.contentView = a; second.contentView = b
        first.makeFirstResponder(a); second.makeFirstResponder(b)
        second.key = true
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: second.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        expect(!TerminalInputRouting.owns(event, view: a, isActive: true), "Background window retaining firstResponder must not intercept Ctrl+C")
        expect(TerminalInputRouting.owns(event, view: b, isActive: true), "Active window receives Ctrl+C")
        expect(!TerminalInputRouting.owns(event, view: b, isActive: false), "Hidden tab must not intercept input")
        first.key = true
        expect(!TerminalInputRouting.owns(event, view: a, isActive: true), "Event must belong to the window even when key state changes")
        second.makeFirstResponder(second)
        expect(!TerminalInputRouting.owns(event, view: b, isActive: true), "Other focused controls must keep input")
    }
}
