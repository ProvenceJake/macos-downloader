import Foundation

enum ShellRunner {
    static func run(
        _ executablePath: String,
        arguments: [String] = [],
        onOutput: ((String) -> Void)? = nil
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let output = LockedOutputBuffer()
            let continuationBox = ContinuationBox(continuation)

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                output.append(data)

                guard let text = String(data: data, encoding: .utf8) else { return }
                let normalized = text.replacingOccurrences(of: "\r", with: "\n")
                for line in normalized.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    DispatchQueue.main.async {
                        onOutput?(line)
                    }
                }
            }

            process.terminationHandler = { finishedProcess in
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                output.append(remaining)
                let finalData = output.snapshot()

                let output = String(data: finalData, encoding: .utf8) ?? ""
                let result = ShellResult(output: output, terminationStatus: finishedProcess.terminationStatus)
                if finishedProcess.terminationStatus == 0 {
                    continuationBox.resume(.success(result))
                } else {
                    let command = ([executablePath] + arguments).joined(separator: " ")
                    continuationBox.resume(.failure(ShellError.failed(command: command, status: finishedProcess.terminationStatus, output: output)))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuationBox.resume(.failure(error))
            }
        }
    }
}

private final class LockedOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}

private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
