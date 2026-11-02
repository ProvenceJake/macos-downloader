import Foundation

final class VisualDownloader: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: (DownloadProgressSnapshot) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destinationURL: URL?
    private var expectedTotalBytes: Int64?
    private var lastSampleDate = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedSpeed: Double = 0
    private var lastEmittedBytes: Int64 = 0
    private var didResume = false
    private let lock = NSLock()

    init(progressHandler: @escaping (DownloadProgressSnapshot) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(from url: URL, to destinationURL: URL, expectedTotalBytes: Int64? = nil) async throws -> URL {
        self.destinationURL = destinationURL
        self.expectedTotalBytes = expectedTotalBytes
        self.lastSampleDate = Date()
        self.lastSampleBytes = 0
        self.smoothedSpeed = 0
        self.lastEmittedBytes = 0
        self.didResume = false

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        let interval = now.timeIntervalSince(lastSampleDate)
        let totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedTotalBytes
        let isComplete = totalBytes.map { totalBytesWritten >= $0 } ?? false
        guard interval >= 0.25 || isComplete || totalBytesWritten - lastEmittedBytes >= 32 * 1024 * 1024 else {
            return
        }

        if interval > 0 {
            let byteDelta = totalBytesWritten - lastSampleBytes
            let instantSpeed = max(Double(byteDelta) / interval, 0)
            smoothedSpeed = smoothedSpeed == 0 ? instantSpeed : (smoothedSpeed * 0.72 + instantSpeed * 0.28)
            lastSampleBytes = totalBytesWritten
            lastSampleDate = now
        }
        lastEmittedBytes = totalBytesWritten

        progressHandler(
            DownloadProgressSnapshot(
                downloadedBytes: totalBytesWritten,
                totalBytes: totalBytes,
                speedBytesPerSecond: smoothedSpeed
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destinationURL else {
            resume(.failure(URLError(.badURL)))
            return
        }

        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            resume(.success(destinationURL))
        } catch {
            resume(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            session.invalidateAndCancel()
            self.session = nil
            self.task = nil
            self.destinationURL = nil
            self.expectedTotalBytes = nil
        }

        guard let error else { return }

        if let destinationURL {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        resume(.failure(error))
    }

    private func resume(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case let .success(url):
            continuation?.resume(returning: url)
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }
}
