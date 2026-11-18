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
    @Published var writeProgress: WriteProgressSnapshot?
    @Published var isDownloading = false
    @Published var isWritingUSB = false
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
        guard !isBusy else { return }
        isBusy = true
        progress = nil
        defer {
            isBusy = false
            currentTask = "准备就绪"
        }

        scanLocalInstallers()
        await refreshUSBVolumes()
        await refreshAvailableInstallers()
    }

    func refreshAvailableInstallers() async {
        currentTask = "正在查询 Apple 完整安装器"
        let selectedID = selectedInstallerID
        installers = InstallerCatalog.fallbackInstallers
        selectedInstallerID = installers.first(where: { $0.id == selectedID })?.id ?? installers.first?.id
        do {
            let packages = try await CatalogResolver.loadInstallAssistantPackages()
            guard !packages.isEmpty else { throw CatalogResolverError.invalidCatalog }
            installers = InstallerCatalog.latestInstallers(from: packages)
            selectedInstallerID = installers.first(where: { $0.id == selectedID })?.id ?? installers.first?.id
            let availableCount = installers.filter {
                if case .installAssistantPackage = $0.source { return true }
                return false
            }.count
            appendLog("已从 Apple 官方目录更新 \(availableCount) 个 macOS 完整安装器版本。", level: .success)
        } catch {
            appendLog("获取最新版本失败：\(error.localizedDescription)", level: .error)
        }
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
        case .softwareUpdate, .installAssistantPackage:
            await resolveAndDownloadInstallAssistant(installer)
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
        isWritingUSB = true
        progress = 0
        writeProgress = WriteProgressSnapshot(phase: "准备", detail: "正在准备写入", fraction: 0)
        currentTask = "正在准备写入"
        appendLog("准备写入：\(installer.displayTitle) -> \(volume.mountPoint)。", level: .warning)
        appendLog("目标磁盘会被抹掉并重建。", level: .warning)

        defer {
            isBusy = false
            isWritingUSB = false
            currentTask = "准备就绪"
        }

        do {
            let preEraseRequired = volume.requiresPreEraseForCreateInstallMedia
            let targetVolumePath = try await prepareVolumeForCreateInstallMediaIfNeeded(volume)

            let shellCommand = [
                shellQuote(installer.createInstallMediaPath),
                "--volume",
                shellQuote(targetVolumePath),
                "--nointeraction"
            ].joined(separator: " ")

            currentTask = "请在终端输入管理员密码"
            updateWriteProgress(
                phase: "写入",
                detail: "请在终端输入管理员密码，并允许访问移动磁盘",
                fraction: preEraseRequired ? 0.15 : 0.02
            )
            let base = preEraseRequired ? 0.15 : 0.0
            let span = 1.0 - base
            appendLog("已在终端启动 Apple 的 createinstallmedia；请在那里输入管理员密码，并允许“终端”访问移动磁盘。", level: .info)
            _ = try await TerminalCommandRunner.run(shellCommand) { [weak self] line in
                self?.appendLog(line, level: .info)
                self?.updateCreateInstallMediaProgress(from: line, base: base, span: span)
            }
            progress = 1
            updateWriteProgress(phase: "完成", detail: "启动盘写入完成", fraction: 1)
            appendLog("启动盘写入完成。", level: .success)
            await refreshUSBVolumes()
        } catch {
            let failure = conciseErrorDescription(error)
            writeProgress = WriteProgressSnapshot(
                phase: "失败",
                detail: "启动盘未写入完成",
                fraction: writeProgress?.fraction
            )
            if failure.contains(".IAPhysicalMedia") || failure.contains("Operation not permitted") {
                appendLog("系统拒绝终端访问移动磁盘。请在“系统设置 > 隐私与安全性 > 文件与文件夹”中允许“终端”访问移动磁盘，然后重试。", level: .warning)
            }
            appendLog("写入失败：\(failure)", level: .error)
        }
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
            let package = try await CatalogResolver.resolveLatest(
                majorVersion: InstallerCatalog.majorVersion(for: installer.version)
            )
            if let index = installers.firstIndex(where: { $0.id == installer.id }) {
                installers[index] = installer.resolved(with: package)
            }
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
        updateWriteProgress(phase: "格式化", detail: "正在准备 \(wholeDiskIdentifier)", fraction: 0.02)
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

        _ = try await PrivilegedCommandRunner.run(shellCommand) { [weak self] line in
            self?.appendLog(line, level: .info)
            self?.updateDiskEraseProgress(from: line)
        }

        guard FileManager.default.fileExists(atPath: expectedMountPoint) else {
            throw USBPreparationError.formattedVolumeNotMounted(expectedMountPoint)
        }

        appendLog("已格式化为 \(expectedMountPoint)，继续写入启动盘。", level: .success)
        updateWriteProgress(phase: "格式化", detail: "格式化完成", fraction: 0.15)
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

    private func updateWriteProgress(phase: String, detail: String, fraction: Double?) {
        let boundedFraction = fraction.map { min(max($0, 0), 1) }
        writeProgress = WriteProgressSnapshot(phase: phase, detail: detail, fraction: boundedFraction)
        progress = boundedFraction
        currentTask = boundedFraction.map {
            "\(phase)：\(Int(($0 * 100).rounded()))% · \(detail)"
        } ?? "\(phase)：\(detail)"
    }

    private func updateDiskEraseProgress(from line: String) {
        let lowercased = line.lowercased()
        let localFraction: Double

        if lowercased.contains("unmount") || line.contains("卸载") {
            localFraction = 0.18
        } else if lowercased.contains("creating the partition map") || lowercased.contains("partition") || line.contains("分区") {
            localFraction = 0.40
        } else if lowercased.contains("formatting") || lowercased.contains("newfs") || line.contains("格式化") {
            localFraction = 0.68
        } else if lowercased.contains("mounting") || line.contains("装载") || line.contains("挂载") {
            localFraction = 0.88
        } else if lowercased.contains("finished erase") || line.contains("完成") {
            localFraction = 1.0
        } else {
            localFraction = 0.08
        }

        updateWriteProgress(
            phase: "格式化",
            detail: line,
            fraction: 0.02 + localFraction * 0.13
        )
    }

    private func updateCreateInstallMediaProgress(from line: String, base: Double, span: Double) {
        let lowercased = line.lowercased()
        let percent = lastPercent(in: line)
        let localFraction: Double

        if lowercased.contains("erasing disk") {
            localFraction = 0.02 + (percent ?? 0) * 0.12
        } else if lowercased.contains("copying essential files") {
            localFraction = 0.16
        } else if lowercased.contains("copying the macos recoveryos") {
            localFraction = 0.22
        } else if lowercased.contains("making disk bootable") {
            localFraction = 0.26
        } else if lowercased.contains("copying to disk") {
            localFraction = 0.28 + (percent ?? 0) * 0.70
        } else if lowercased.contains("copying boot files") {
            localFraction = 0.25
        } else if lowercased.contains("install media now available") {
            localFraction = 1.0
        } else {
            localFraction = 0.02
        }

        let previousFraction = writeProgress?.fraction ?? base
        let nextFraction = base + min(max(localFraction, 0), 1) * span

        updateWriteProgress(
            phase: "写入",
            detail: line,
            fraction: max(previousFraction, nextFraction)
        )
    }

    private func lastPercent(in line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)%"#) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.matches(in: line, range: range).last,
              let percentRange = Range(match.range(at: 1), in: line),
              let value = Double(line[percentRange]) else {
            return nil
        }
        return min(max(value / 100, 0), 1)
    }

    private func conciseErrorDescription(_ error: Error) -> String {
        if case let ShellError.failed(_, status, output) = error {
            let meaningfulLines = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("__MACOS_DOWNLOADER_") }
            let tail = meaningfulLines.suffix(5).joined(separator: "\n")
            if tail.isEmpty {
                return "命令退出，状态码 \(status)。"
            }
            return "命令退出，状态码 \(status)：\(tail)"
        }
        return error.localizedDescription
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
