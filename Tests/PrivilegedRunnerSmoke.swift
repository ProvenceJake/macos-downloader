import Foundation

@main
struct PrivilegedRunnerSmoke {
    @MainActor
    static func main() async throws {
        for (command, expectedStatus) in [
            ("/bin/echo test-line; /usr/bin/true", Int32(0)),
            ("/bin/echo test-line; /usr/bin/false", Int32(1))
        ] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacOSDownloader-RunnerTest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let logURL = directory.appendingPathComponent("command.log")
            let scriptURL = directory.appendingPathComponent("run.zsh")
            try PrivilegedCommandRunner.makeScript(command: command, logURL: logURL)
                .write(to: scriptURL, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path]
            try process.run()
            process.waitUntilExit()

            let log = try String(contentsOf: logURL, encoding: .utf8)
            precondition(process.terminationStatus == expectedStatus)
            precondition(log.contains("test-line"))
            precondition(log.contains("__MACOS_DOWNLOADER_EXIT_STATUS__:\(expectedStatus)"))
            precondition(!log.contains("read-only variable"))

            let terminalLogURL = directory.appendingPathComponent("terminal.log")
            let terminalScriptURL = directory.appendingPathComponent("write.command")
            try TerminalCommandRunner.makeScript(command: command, logURL: terminalLogURL)
                .write(to: terminalScriptURL, atomically: true, encoding: .utf8)

            let terminalProcess = Process()
            terminalProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
            terminalProcess.arguments = [terminalScriptURL.path]
            try terminalProcess.run()
            terminalProcess.waitUntilExit()

            let terminalLog = try String(contentsOf: terminalLogURL, encoding: .utf8)
            precondition(terminalProcess.terminationStatus == expectedStatus)
            precondition(terminalLog.contains("__MACOS_DOWNLOADER_STARTED__"))
            precondition(terminalLog.contains("__MACOS_DOWNLOADER_PID__:"))
            precondition(terminalLog.contains("test-line"))
            precondition(terminalLog.contains("__MACOS_DOWNLOADER_EXIT_STATUS__:\(expectedStatus)"))
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSDownloader-ProgressTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("progress.log")
        try Data("Copying to disk: 0%... ".utf8).write(to: logURL)
        let poller = LogFilePoller(logURL: logURL)
        var lines: [String] = []
        await poller.flush(onOutput: { lines.append($0) }, emitPartial: false)
        precondition(lines == ["Copying to disk: 0%"])

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("10%... 20%...\n__MACOS_DOWNLOADER_EXIT_STATUS__:0\n".utf8))
        try handle.close()
        await poller.flush(onOutput: { lines.append($0) }, emitPartial: false)
        precondition(lines == ["Copying to disk: 0%", "Copying to disk: 20%"])
        let finalState = await poller.state()
        precondition(finalState.exitStatus == 0)
        print("Privileged and Terminal command wrappers: success, failure, and live progress passed")
    }
}
