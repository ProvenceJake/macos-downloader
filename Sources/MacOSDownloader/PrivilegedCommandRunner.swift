import AppKit
import Darwin
import Foundation

enum PrivilegedCommandRunner {
    static func run(
        _ command: String,
        onOutput: @escaping @MainActor (String) -> Void
    ) async throws -> ShellResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSDownloader-Privileged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let logURL = temporaryDirectory.appendingPathComponent("command.log")
        let scriptURL = temporaryDirectory.appendingPathComponent("run.zsh")
        try Data().write(to: logURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: logURL.path)

        let script = makeScript(command: command, logURL: logURL)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let runner = Task {
            let shellCommand = "\(shellQuote("/bin/zsh")) \(shellQuote(scriptURL.path))"
            let appleScript = "do shell script \(appleScriptLiteral(shellCommand)) with administrator privileges"
            return try await ShellRunner.run("/usr/bin/osascript", arguments: ["-e", appleScript])
        }

        let poller = LogFilePoller(logURL: logURL)
        let pollTask = Task {
            await poller.poll(onOutput: onOutput)
        }

        do {
            let osascriptResult = try await runner.value
            pollTask.cancel()
            await poller.flush(onOutput: onOutput)
            let logOutput = (try? String(contentsOf: logURL, encoding: .utf8)) ?? osascriptResult.output
            let status = exitStatus(from: logOutput) ?? osascriptResult.terminationStatus
            if status == 0 {
                return ShellResult(output: logOutput, terminationStatus: status)
            }
            throw ShellError.failed(command: command, status: status, output: logOutput)
        } catch {
            pollTask.cancel()
            await poller.flush(onOutput: onOutput)
            let logOutput = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if !logOutput.isEmpty {
                let status = exitStatus(from: logOutput) ?? 1
                throw ShellError.failed(command: command, status: status, output: logOutput)
            }
            throw error
        }
    }

    static func makeScript(command: String, logURL: URL) -> String {
        """
        #!/bin/zsh
        set +e
        {
          echo "__MACOS_DOWNLOADER_STARTED__"
          \(command)
          command_exit_code=$?
          echo "__MACOS_DOWNLOADER_EXIT_STATUS__:${command_exit_code}"
          exit ${command_exit_code}
        } > \(shellQuote(logURL.path)) 2>&1
        """
    }

    private static func exitStatus(from output: String) -> Int32? {
        let marker = "__MACOS_DOWNLOADER_EXIT_STATUS__:"
        guard let line = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix(marker) }) else {
            return nil
        }
        return Int32(line.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

enum TerminalCommandRunner {
    @MainActor
    static func run(
        _ command: String,
        onOutput: @escaping @MainActor (String) -> Void
    ) async throws -> ShellResult {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSDownloader-Terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryDirectory.path)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let logURL = temporaryDirectory.appendingPathComponent("command.log")
        let scriptURL = temporaryDirectory.appendingPathComponent("write.command")
        try Data().write(to: logURL)
        try makeScript(command: "/usr/bin/sudo -- \(command)", logURL: logURL)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        guard NSWorkspace.shared.open(scriptURL) else {
            throw TerminalCommandError.couldNotOpen
        }

        let poller = LogFilePoller(logURL: logURL)
        let launchedAt = Date()

        while true {
            await poller.flush(onOutput: onOutput, emitPartial: false)
            let state = await poller.state()

            if let status = state.exitStatus {
                await poller.flush(onOutput: onOutput)
                let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                if status == 0 {
                    return ShellResult(output: output, terminationStatus: status)
                }
                throw ShellError.failed(command: command, status: status, output: output)
            }

            if !state.started && Date().timeIntervalSince(launchedAt) > 120 {
                throw TerminalCommandError.didNotStart
            }
            if let pid = state.processID, kill(pid, 0) == -1 && errno == ESRCH {
                throw TerminalCommandError.interrupted
            }

            try await Task.sleep(for: .milliseconds(250))
        }
    }

    static func makeScript(command: String, logURL: URL) -> String {
        """
        #!/bin/zsh
        set +e
        set -o pipefail
        printf '%s\\n' '__MACOS_DOWNLOADER_STARTED__' "__MACOS_DOWNLOADER_PID__:$$" >> \(shellQuote(logURL.path))
        printf '%s\\n' 'macOS 下载器：请在此输入管理员密码，并允许“终端”访问移动磁盘。'
        {
          \(command)
        } 2>&1 | /usr/bin/tee -a \(shellQuote(logURL.path))
        command_exit_code=$?
        printf '__MACOS_DOWNLOADER_EXIT_STATUS__:%s\\n' "$command_exit_code" >> \(shellQuote(logURL.path))
        printf '写入命令结束，状态码：%s\\n' "$command_exit_code"
        exit "$command_exit_code"
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private enum TerminalCommandError: LocalizedError {
    case couldNotOpen
    case didNotStart
    case interrupted

    var errorDescription: String? {
        switch self {
        case .couldNotOpen:
            return "无法打开终端来写入 U 盘。请确认“终端”应用可用。"
        case .didNotStart:
            return "终端中的写入脚本未启动。请检查终端窗口，并重试。"
        case .interrupted:
            return "终端中的写入脚本已中断。请保持终端窗口打开直到写入完成。"
        }
    }
}

struct RunnerLogState {
    let started: Bool
    let processID: Int32?
    let exitStatus: Int32?
}

actor LogFilePoller {
    private let logURL: URL
    private var offset: UInt64 = 0
    private var partialLineBytes: [UInt8] = []
    private var emittedLines = Set<String>()
    private var lastEmittedProgressLine: String?
    private var started = false
    private var processID: Int32?
    private var exitStatus: Int32?

    init(logURL: URL) {
        self.logURL = logURL
    }

    func state() -> RunnerLogState {
        RunnerLogState(started: started, processID: processID, exitStatus: exitStatus)
    }

    func poll(onOutput: @escaping @MainActor (String) -> Void) async {
        while !Task.isCancelled {
            await flush(onOutput: onOutput, emitPartial: false)
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func flush(
        onOutput: @escaping @MainActor (String) -> Void,
        emitPartial: Bool = true
    ) async {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            offset += UInt64(data.count)
            for byte in data {
                if byte == 10 || byte == 13 {
                    await emit(String(decoding: partialLineBytes, as: UTF8.self), onOutput: onOutput)
                    partialLineBytes.removeAll(keepingCapacity: true)
                } else {
                    partialLineBytes.append(byte)
                }
            }
            if !emitPartial && partialLineBytes.contains(37) {
                await emit(String(decoding: partialLineBytes, as: UTF8.self), onOutput: onOutput)
            }
            if emitPartial && !partialLineBytes.isEmpty {
                await emit(String(decoding: partialLineBytes, as: UTF8.self), onOutput: onOutput)
                partialLineBytes.removeAll(keepingCapacity: true)
            }
        } catch {
            return
        }
    }

    private func emit(_ rawLine: String, onOutput: @escaping @MainActor (String) -> Void) async {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if line == "__MACOS_DOWNLOADER_STARTED__" {
            started = true
            return
        }
        if line.hasPrefix("__MACOS_DOWNLOADER_PID__:") {
            processID = Int32(line.dropFirst("__MACOS_DOWNLOADER_PID__:".count))
            return
        }
        if line.hasPrefix("__MACOS_DOWNLOADER_EXIT_STATUS__:") {
            exitStatus = Int32(line.dropFirst("__MACOS_DOWNLOADER_EXIT_STATUS__:".count))
            return
        }

        let displayLine = summarizedProgressLine(line) ?? line
        if displayLine.contains("%") {
            guard displayLine != lastEmittedProgressLine else { return }
            lastEmittedProgressLine = displayLine
        } else {
            guard !emittedLines.contains(displayLine) else { return }
            emittedLines.insert(displayLine)
            if emittedLines.count > 500 {
                emittedLines.removeAll(keepingCapacity: true)
            }
        }

        await MainActor.run {
            onOutput(displayLine)
        }
    }

    private func summarizedProgressLine(_ line: String) -> String? {
        let lowercased = line.lowercased()
        guard lowercased.hasPrefix("erasing disk:") || lowercased.hasPrefix("copying to disk:") else {
            return nil
        }
        guard let colon = line.firstIndex(of: ":"),
              let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?%"#) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.matches(in: line, range: range).last,
              let percentRange = Range(match.range, in: line) else {
            return nil
        }
        return "\(line[...colon]) \(line[percentRange])"
    }
}
