import Foundation

enum InstallerSource: Hashable {
    case softwareUpdate
    case installAssistantPackage(URL)
    case legacyDMG(URL)

    var label: String {
        switch self {
        case .softwareUpdate:
            return "待解析"
        case .installAssistantPackage:
            return "可视下载"
        case .legacyDMG:
            return "Apple DMG"
        }
    }
}

struct InstallerOption: Identifiable, Hashable {
    let id: String
    let title: String
    let version: String
    let build: String?
    let sizeHint: String?
    let source: InstallerSource
    let note: String

    init(
        id: String,
        title: String,
        version: String,
        build: String?,
        sizeHint: String?,
        source: InstallerSource,
        note: String
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.build = build
        self.sizeHint = sizeHint
        self.source = source
        self.note = note
    }

    var displayTitle: String {
        "\(title) \(version)"
    }

    func resolved(with package: InstallAssistantPackage) -> InstallerOption {
        InstallerOption(
            id: id,
            title: package.title,
            version: package.version,
            build: package.build,
            sizeHint: ByteCountFormatter.string(fromByteCount: package.sizeBytes, countStyle: .file),
            source: .installAssistantPackage(package.url),
            note: "使用 Apple InstallAssistant.pkg 前台下载，显示进度和速度，完成后安装到“应用程序”。"
        )
    }
}

struct InstallAssistantPackage: Identifiable, Hashable {
    let id: String
    let title: String
    let version: String
    let build: String
    let sizeBytes: Int64
    let url: URL
    let postDate: Date?
}

struct DownloadProgressSnapshot {
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let speedBytesPerSecond: Double

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }

    var downloadedText: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var totalText: String {
        guard let totalBytes else { return "大小未知" }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var speedText: String {
        guard speedBytesPerSecond > 0 else { return "计算中" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSecond), countStyle: .file))/s"
    }

    var percentText: String {
        guard let fraction else { return "--" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    var remainingText: String {
        guard let totalBytes, totalBytes > downloadedBytes else { return "剩余未知" }
        let remainingBytes = totalBytes - downloadedBytes
        return "剩余 \(ByteCountFormatter.string(fromByteCount: remainingBytes, countStyle: .file))"
    }
}

struct WriteProgressSnapshot {
    let phase: String
    let detail: String
    let fraction: Double?

    var percentText: String {
        guard let fraction else { return "--" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

struct LocalInstaller: Identifiable, Hashable {
    let id: String
    let name: String
    let appPath: String
    let createInstallMediaPath: String
    let version: String?

    var displayTitle: String {
        if let version, !version.isEmpty {
            return "\(name) \(version)"
        }
        return name
    }
}

struct USBVolume: Identifiable, Hashable {
    let id: String
    let name: String
    let mountPoint: String
    let deviceIdentifier: String
    let wholeDiskIdentifier: String?
    let sizeBytes: Int64?
    let content: String?
    let filesystemName: String?

    var displayTitle: String {
        "\(name) (\(deviceIdentifier))"
    }

    var sizeDescription: String {
        guard let sizeBytes else { return "容量未知" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var filesystemDescription: String {
        filesystemName ?? content ?? "格式未知"
    }

    var requiresPreEraseForCreateInstallMedia: Bool {
        filesystemDescription.localizedCaseInsensitiveContains("APFS")
    }

    var eraseTargetDescription: String {
        if let wholeDiskIdentifier {
            return "\(displayTitle) 所在的整只外接磁盘 \(wholeDiskIdentifier)"
        }
        return displayTitle
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let level: LogLevel
}

enum LogLevel {
    case info
    case success
    case warning
    case error
}

struct ShellResult {
    let output: String
    let terminationStatus: Int32
}

enum ShellError: LocalizedError {
    case failed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .failed(command, status, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "\(command) 退出，状态码 \(status)。"
            }
            return "\(command) 退出，状态码 \(status)：\(trimmed)"
        }
    }
}
