import AppKit
import Foundation

@main
struct TerminalLaunchSmoke {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSDownloader-TerminalSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let markerURL = directory.appendingPathComponent("launched.txt")
        let scriptURL = directory.appendingPathComponent("smoke.command")
        let quotedMarker = "'\(markerURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        try "#!/bin/zsh\n/bin/echo launched > \(quotedMarker)\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        guard NSWorkspace.shared.open(scriptURL) else {
            throw SmokeError.couldNotOpen
        }

        for _ in 0..<80 {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                print("Terminal launched and executed a generated .command script")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SmokeError.didNotExecute
    }
}

private enum SmokeError: Error {
    case couldNotOpen
    case didNotExecute
}
