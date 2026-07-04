import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var installers: [InstallerOption] = InstallerCatalog.fallbackInstallers
    @Published var localInstallers: [LocalInstaller] = []
    @Published var usbVolumes: [USBVolume] = []
    @Published var selectedInstallerID: InstallerOption.ID?
    @Published var selectedLocalInstallerID: LocalInstaller.ID?
    @Published var selectedVolumeID: USBVolume.ID?
    @Published var logEntries: [LogEntry] = []
    @Published var isBusy = false
    @Published var currentTask = "准备就绪"
    @Published var progress: Double?
    @Published var downloadProgress: DownloadProgressSnapshot?
    @Published var isDownloading = false
    @Published var showEraseConfirmation = false

    private var activeDownloader: VisualDownloader?

    var selectedInstaller: InstallerOption? {
        installers.first { $0.id == selectedInstallerID } ?? installers.first
    }

    var selectedLocalInstaller: LocalInstaller? {
        localInstallers.first { $0.id == selectedLocalInstallerID } ?? localInstallers.first
    }

    var selectedVolume: USBVolume? {
        usbVolumes.first { $0.id == selectedVolumeID } ?? usbVolumes.first
    }

    func refreshAll() async {
        refreshDownloadOptions()
        scanLocalInstallers()
        await refreshUSBVolumes()
    }

    func refreshDownloadOptions() {
        let previousVersion = selectedInstaller?.version
        installers = InstallerCatalog.fallbackInstallers
        selectedInstallerID = previousVersion.flatMap { version in
            installers.first { $0.version == version }?.id
        } ?? installers.first?.id
        appendLog("已加载下载列表。下载时才解析 Apple 官方地址，避免启动时占用 CPU。", level: .success)
    }

    func refreshAvailableInstallers() async {
        refreshDownloadOptions()
    }

    func scanLocalInstallers() {
        localInstallers = InstallerCatalog.scanLocalInstallers()
        selectedLocalInstallerID = localInstallers.first?.id
        if localInstallers.isEmpty {
            appendLog("未在 /Applications 中发现可写入 U 盘的 macOS 安装器。", level: .warning)
        } else {
            appendLog("发现 \(localInstallers.count) 个本地 macOS 安装器。", level: .success)
        }
    }

    func refreshUSBVolumes() async {
        currentTask = "正在扫描外接磁盘"

        do {
            let result = try await ShellRunner.run("/usr/sbin/diskutil", arguments: ["list", "-plist", "external"])
            let listedVolumes = parseUSBVolumes(from: result.output)
            let mountedVolumes = await scanMountedExternalVolumes()
            usbVolumes = mergeUSBVolumes(listedVolumes + mountedVolumes)
            selectedVolumeID = usbVolumes.first?.id
            if usbVolumes.isEmpty {
                appendLog("未发现已挂载的外接 U 盘或移动磁盘。", level: .warning)
            } else {
                appendLog("发现 \(usbVolumes.count) 个外接卷。", level: .success)
            }
        } catch {
            usbVolumes = []
            selectedVolumeID = nil
            appendLog("扫描外接磁盘失败：\(error.localizedDescription)", level: .error)
        }

        currentTask = "准备就绪"
    }

    func downloadSelectedInstaller() async {
        guard !isBusy else { return }
        guard let installer = selectedInstaller else {
            appendLog("请先选择一个 macOS 版本。", level: .warning)
            return
        }

        isBusy = true
        progress = nil
        downloadProgress = nil
        defer {
            isBusy = false
            isDownloading = false
            activeDownloader = nil
            currentTask = "准备就绪"
        }

        switch installer.source {
        case .softwareUpdate:
            await resolveAndDownloadInstallAssistant(installer)
        case let .installAssistantPackage(url):
            await downloadInstallAssistant(installer, packageURL: url, expectedSize: nil)
        case let .legacyDMG(url):
            await downloadLegacyDMG(installer, url: url)
        }
    }

    func cancelDownload() {
        guard isDownloading else { return }
        currentTask = "正在取消下载"
        appendLog("正在取消当前下载。", level: .warning)
        activeDownloader?.cancel()
    }

    func requestWriteConfirmation() {
        guard !isBusy else { return }
        guard selectedLocalInstaller != nil else {
            appendLog("请先下载或选择一个位于 /Applications 的 macOS 安装器。", level: .warning)
            return
        }
        guard selectedVolume != nil else {
            appendLog("请先插入并选择一个 U 盘卷。", level: .warning)
            return
        }
        showEraseConfirmation = true
    }

    func writeBootableUSB() async {
        guard !isBusy else { return }
        guard let installer = selectedLocalInstaller, let volume = selectedVolume else { return }

        isBusy = true
        progress = nil
        currentTask = "正在请求管理员授权"
        appendLog("准备写入：\(installer.displayTitle) -> \(volume.mountPoint)。", level: .warning)
        appendLog("目标磁盘会被抹掉并重建。", level: .warning)

        let targetVolumePath: String
        do {
            targetVolumePath = try await prepareVolumeForCreateInstallMediaIfNeeded(volume)
        } catch {
            appendLog("准备 U 盘失败：\(error.localizedDescription)", level: .error)
            isBusy = false
            currentTask = "准备就绪"
            return
        }

        let shellCommand = [
            shellQuote(installer.createInstallMediaPath),
            "--volume",
            shellQuote(targetVolumePath),
            "--nointeraction"
        ].joined(separator: " ")

        let script = "do shell script \(appleScriptLiteral(shellCommand)) with administrator privileges"

        do {
            currentTask = "正在写入启动盘"
            let result = try await ShellRunner.run("/usr/bin/osascript", arguments: ["-e", script]) { [weak self] line in
                self?.appendLog(line, level: .info)
            }
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendLog(trimmed, level: .info)
            }
            progress = 1
            appendLog("启动盘写入完成。", level: .success)
            await refreshUSBVolumes()
        } catch {
            appendLog("写入失败：\(error.localizedDescription)", level: .error)
        }

        isBusy = false
        currentTask = "准备就绪"
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func openDownloadsFolder() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if let downloads {
            NSWorkspace.shared.open(downloads)
        }
    }

    func clearLog() {
        logEntries.removeAll()
    }

    private func resolveAndDownloadInstallAssistant(_ installer: InstallerOption) async {
        currentTask = "正在解析 \(installer.displayTitle)"
        appendLog("正在从 Apple 软件更新目录解析 \(installer.displayTitle) 的 InstallAssistant.pkg。", level: .info)

        do {
            let package = try await CatalogResolver.resolve(version: installer.version)
            await downloadInstallAssistant(installer.resolved(with: package), packageURL: package.url, expectedSize: package.sizeBytes)
        } catch {
            appendLog("解析下载地址失败：\(error.localizedDescription)", level: .error)
        }
    }

    private func downloadInstallAssistant(_ installer: InstallerOption, packageURL: URL, expectedSize: Int64?) async {
        currentTask = "正在前台下载 \(installer.displayTitle)"
        progress = 0
        isDownloading = true
        appendLog("开始前台下载 \(installer.displayTitle)。", level: .info)

        let destination = temporaryPackageURL(for: installer)
        let downloader = VisualDownloader { [weak self] snapshot in
            Task { @MainActor in
                self?.downloadProgress = snapshot
                self?.progress = snapshot.fraction
                self?.currentTask = "正在下载 \(snapshot.downloadedText) / \(snapshot.totalText) · \(snapshot.speedText)"
            }
        }
        activeDownloader = downloader

        let downloadedURL: URL
        do {
            downloadedURL = try await downloader.download(
                from: packageURL,
                to: destination,
                expectedTotalBytes: expectedSize
            )
        } catch {
            isDownloading = false
            if (error as NSError).code == NSURLErrorCancelled {
                try? FileManager.default.removeItem(at: destination)
                appendLog("下载已取消，临时文件已删除。", level: .warning)
            } else {
                appendLog("前台下载失败：\(error.localizedDescription)", level: .error)
            }
            return
        }

        isDownloading = false
        progress = 1
        appendLog("下载完成：\(downloadedURL.path)。", level: .success)

        do {
            try await installAssistantPackage(downloadedURL)
            try? FileManager.default.removeItem(at: downloadedURL)
            appendLog("已删除临时 pkg：\(downloadedURL.lastPathComponent)。", level: .success)
            scanLocalInstallers()
        } catch {
            appendLog("pkg 安装失败：\(error.localizedDescription)", level: .error)
            appendLog("已保留 pkg：\(downloadedURL.path)。", level: .warning)
        }
    }

    private func downloadLegacyDMG(_ installer: InstallerOption, url: URL) async {
        currentTask = "正在下载 \(installer.displayTitle)"
        progress = 0
        isDownloading = true
        appendLog("开始下载 \(installer.displayTitle) DMG。", level: .info)

        do {
            let fileName = url.lastPathComponent.isEmpty ? "InstallMacOSX.dmg" : url.lastPathComponent
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let destination = downloads.appendingPathComponent(fileName)
            let downloader = VisualDownloader { [weak self] snapshot in
                Task { @MainActor in
                    self?.downloadProgress = snapshot
                    self?.progress = snapshot.fraction
                    self?.currentTask = "正在下载 \(snapshot.downloadedText) / \(snapshot.totalText) · \(snapshot.speedText)"
                }
            }
            activeDownloader = downloader
            let downloadedURL = try await downloader.download(from: url, to: destination)
            isDownloading = false
            progress = 1
            appendLog("DMG 已保存到 \(destination.path)。", level: .success)
            NSWorkspace.shared.activateFileViewerSelecting([downloadedURL])
        } catch {
            isDownloading = false
            if (error as NSError).code == NSURLErrorCancelled {
                appendLog("DMG 下载已取消，临时文件已删除。", level: .warning)
            } else {
                appendLog("DMG 下载失败：\(error.localizedDescription)", level: .error)
            }
        }
    }

    private func installAssistantPackage(_ packageURL: URL) async throws {
        currentTask = "正在安装到应用程序"
        appendLog("正在安装 pkg，系统会请求管理员权限。", level: .info)

        let shellCommand = [
            "/usr/sbin/installer",
            "-pkg",
            shellQuote(packageURL.path),
            "-target",
            "/"
        ].joined(separator: " ")

        let script = "do shell script \(appleScriptLiteral(shellCommand)) with administrator privileges"
        let result = try await ShellRunner.run("/usr/bin/osascript", arguments: ["-e", script]) { [weak self] line in
            self?.appendLog(line, level: .info)
        }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appendLog(trimmed, level: .info)
        }
        appendLog("安装器已安装到 /Applications。", level: .success)
    }

    private func prepareVolumeForCreateInstallMediaIfNeeded(_ volume: USBVolume) async throws -> String {
        guard volume.requiresPreEraseForCreateInstallMedia else {
            return volume.mountPoint
        }

        guard let wholeDiskIdentifier = volume.wholeDiskIdentifier else {
            throw USBPreparationError.missingWholeDisk(volume.displayTitle)
        }

        let temporaryVolumeName = "InstallMedia-\(String(UUID().uuidString.prefix(6)))"
        let expectedMountPoint = "/Volumes/\(temporaryVolumeName)"

        currentTask = "正在格式化 U 盘"
        appendLog("目标卷是 \(volume.filesystemDescription)，createinstallmedia 不能直接使用 APFS。", level: .warning)
        appendLog("将先抹掉整只外接磁盘 \(wholeDiskIdentifier)，格式化为 Mac OS Extended (Journaled)。", level: .warning)

        let shellCommand = [
            "/usr/sbin/diskutil",
            "eraseDisk",
            "JHFS+",
            shellQuote(temporaryVolumeName),
            "GPT",
            shellQuote("/dev/\(wholeDiskIdentifier)")
        ].joined(separator: " ")

        let script = "do shell script \(appleScriptLiteral(shellCommand)) with administrator privileges"
        let result = try await ShellRunner.run("/usr/bin/osascript", arguments: ["-e", script]) { [weak self] line in
            self?.appendLog(line, level: .info)
        }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appendLog(trimmed, level: .info)
        }

        guard FileManager.default.fileExists(atPath: expectedMountPoint) else {
            throw USBPreparationError.formattedVolumeNotMounted(expectedMountPoint)
        }

        appendLog("已格式化为 \(expectedMountPoint)，继续写入启动盘。", level: .success)
        return expectedMountPoint
    }

    private func temporaryPackageURL(for installer: InstallerOption) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacOSDownloader", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        let safeVersion = installer.version.replacingOccurrences(of: "/", with: "-")
        return support.appendingPathComponent("InstallAssistant-\(safeVersion).pkg")
    }

    private func appendLog(_ message: String, level: LogLevel) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logEntries.append(LogEntry(message: trimmed, level: level))
        if logEntries.count > 300 {
            logEntries.removeFirst(logEntries.count - 300)
        }
    }

    private func parseUSBVolumes(from plistOutput: String) -> [USBVolume] {
        guard let data = plistOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any] else {
            return []
        }

        var volumes: [USBVolume] = []
        collectUSBVolumes(from: root, into: &volumes)
        return mergeUSBVolumes(volumes)
    }

    private func collectUSBVolumes(from value: Any, into volumes: inout [USBVolume]) {
        if let dictionary = value as? [String: Any] {
            if let volume = usbVolume(fromDiskutilDictionary: dictionary) {
                volumes.append(volume)
            }

            for child in dictionary.values {
                collectUSBVolumes(from: child, into: &volumes)
            }
            return
        }

        if let array = value as? [Any] {
            for child in array {
                collectUSBVolumes(from: child, into: &volumes)
            }
        }
    }

    private func usbVolume(fromDiskutilDictionary dictionary: [String: Any]) -> USBVolume? {
        guard
            let mountPoint = dictionary["MountPoint"] as? String,
            mountPoint != "/",
            let deviceIdentifier = dictionary["DeviceIdentifier"] as? String
        else {
            return nil
        }

        let isInternal = (dictionary["OSInternal"] as? Bool)
            ?? (dictionary["Internal"] as? Bool)
            ?? false
        guard !isInternal else { return nil }

        let name = dictionary["VolumeName"] as? String
            ?? URL(fileURLWithPath: mountPoint).lastPathComponent
        let content = dictionary["Content"] as? String
            ?? dictionary["FilesystemName"] as? String
        let size = (dictionary["Size"] as? NSNumber)?.int64Value
            ?? (dictionary["TotalSize"] as? NSNumber)?.int64Value

        return USBVolume(
            id: mountPoint,
            name: name,
            mountPoint: mountPoint,
            deviceIdentifier: deviceIdentifier,
            wholeDiskIdentifier: wholeDiskIdentifier(from: dictionary),
            sizeBytes: size,
            content: content,
            filesystemName: dictionary["FilesystemName"] as? String
                ?? dictionary["FilesystemUserVisibleName"] as? String
        )
    }

    private func scanMountedExternalVolumes() async -> [USBVolume] {
        let volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let mountedURLs = try? FileManager.default.contentsOfDirectory(
            at: volumesRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var volumes: [USBVolume] = []
        for url in mountedURLs {
            let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true {
                continue
            }

            guard let info = try? await ShellRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", url.path]),
                  let data = info.output.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = plist as? [String: Any],
                  let volume = mountedExternalVolume(fromInfoDictionary: dictionary, fallbackURL: url)
            else {
                continue
            }
            volumes.append(volume)
        }

        return mergeUSBVolumes(volumes)
    }

    private func mountedExternalVolume(fromInfoDictionary dictionary: [String: Any], fallbackURL: URL) -> USBVolume? {
        let mountPoint = dictionary["MountPoint"] as? String ?? fallbackURL.path
        guard mountPoint != "/" else { return nil }

        let isInternal = dictionary["Internal"] as? Bool ?? true
        let isRemovable = dictionary["Removable"] as? Bool ?? false
        let isEjectable = dictionary["Ejectable"] as? Bool ?? false
        let busProtocol = dictionary["BusProtocol"] as? String ?? ""
        guard !isInternal || isRemovable || isEjectable || busProtocol.caseInsensitiveCompare("USB") == .orderedSame else {
            return nil
        }

        guard let deviceIdentifier = dictionary["DeviceIdentifier"] as? String else {
            return nil
        }

        let name = dictionary["VolumeName"] as? String ?? fallbackURL.lastPathComponent
        let content = dictionary["FilesystemName"] as? String
            ?? dictionary["Content"] as? String
        let size = (dictionary["TotalSize"] as? NSNumber)?.int64Value
            ?? (dictionary["Size"] as? NSNumber)?.int64Value

        return USBVolume(
            id: mountPoint,
            name: name,
            mountPoint: mountPoint,
            deviceIdentifier: deviceIdentifier,
            wholeDiskIdentifier: wholeDiskIdentifier(from: dictionary),
            sizeBytes: size,
            content: content,
            filesystemName: dictionary["FilesystemName"] as? String
                ?? dictionary["FilesystemUserVisibleName"] as? String
        )
    }

    private func mergeUSBVolumes(_ volumes: [USBVolume]) -> [USBVolume] {
        var unique: [USBVolume] = []
        for volume in volumes {
            let key = volume.mountPoint
            if let index = unique.firstIndex(where: { $0.mountPoint == key }) {
                let existing = unique[index]
                if existing.wholeDiskIdentifier == nil && volume.wholeDiskIdentifier != nil {
                    unique[index] = volume
                }
            } else {
                unique.append(volume)
            }
        }

        return unique.sorted { lhs, rhs in
            lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    private func wholeDiskIdentifier(from dictionary: [String: Any]) -> String? {
        if
            let stores = dictionary["APFSPhysicalStores"] as? [[String: Any]],
            let storeIdentifier = stores.compactMap({ $0["APFSPhysicalStore"] as? String ?? $0["DeviceIdentifier"] as? String }).first
        {
            return physicalWholeDiskIdentifier(from: storeIdentifier)
        }

        if let parentWholeDisk = dictionary["ParentWholeDisk"] as? String {
            return parentWholeDisk
        }

        if
            let wholeDisk = dictionary["WholeDisk"] as? Bool,
            wholeDisk,
            let deviceIdentifier = dictionary["DeviceIdentifier"] as? String,
            (dictionary["VirtualOrPhysical"] as? String)?.localizedCaseInsensitiveContains("Physical") == true
        {
            return deviceIdentifier
        }

        return nil
    }

    private func physicalWholeDiskIdentifier(from identifier: String) -> String {
        identifier.replacingOccurrences(of: #"s\d+$"#, with: "", options: .regularExpression)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

enum USBPreparationError: LocalizedError {
    case missingWholeDisk(String)
    case formattedVolumeNotMounted(String)

    var errorDescription: String? {
        switch self {
        case let .missingWholeDisk(volume):
            return "无法确定 \(volume) 所在的外接物理磁盘，已停止以避免误擦磁盘。"
        case let .formattedVolumeNotMounted(path):
            return "格式化完成后没有找到新挂载点 \(path)。"
        }
    }
}
