import AppKit
import Foundation

enum InstallerCatalog {
    static let modernInstallers: [InstallerOption] = [
        InstallerOption(
            id: "modern-tahoe-26.5.2",
            title: "macOS Tahoe",
            version: "26.5.2",
            build: nil,
            sizeHint: nil,
            source: .softwareUpdate,
            note: "新版快捷入口。点击下载时才解析 Apple 官方地址，避免启动时占用 CPU。"
        ),
        InstallerOption(
            id: "modern-sequoia-15.7.7",
            title: "macOS Sequoia",
            version: "15.7.7",
            build: nil,
            sizeHint: nil,
            source: .softwareUpdate,
            note: "新版快捷入口。点击下载时才解析 Apple 官方地址，避免启动时占用 CPU。"
        ),
        InstallerOption(
            id: "modern-sonoma-14.8.7",
            title: "macOS Sonoma",
            version: "14.8.7",
            build: nil,
            sizeHint: nil,
            source: .softwareUpdate,
            note: "新版快捷入口。点击下载时才解析 Apple 官方地址，避免启动时占用 CPU。"
        ),
        InstallerOption(
            id: "modern-ventura-13.7.8",
            title: "macOS Ventura",
            version: "13.7.8",
            build: nil,
            sizeHint: nil,
            source: .softwareUpdate,
            note: "新版快捷入口。点击下载时才解析 Apple 官方地址，避免启动时占用 CPU。"
        )
    ]

    static var fallbackInstallers: [InstallerOption] {
        modernInstallers + legacyInstallers
    }

    static let legacyInstallers: [InstallerOption] = [
        InstallerOption(
            id: "legacy-sierra-10.12",
            title: "macOS Sierra",
            version: "10.12",
            build: nil,
            sizeHint: nil,
            source: .legacyDMG(URL(string: "http://updates-http.cdn-apple.com/2019/cert/061-39476-20191023-48f365f4-0015-4c41-9f44-39d3d2aca067/InstallOS.dmg")!),
            note: "下载 DMG 后需打开其中的 PKG，将安装器放入“应用程序”。"
        ),
        InstallerOption(
            id: "legacy-el-capitan-10.11",
            title: "OS X El Capitan",
            version: "10.11",
            build: nil,
            sizeHint: nil,
            source: .legacyDMG(URL(string: "http://updates-http.cdn-apple.com/2019/cert/061-41424-20191024-218af9ec-cf50-4516-9011-228c78eda3d2/InstallMacOSX.dmg")!),
            note: "下载 DMG 后需打开其中的 PKG，将安装器放入“应用程序”。"
        ),
        InstallerOption(
            id: "legacy-yosemite-10.10",
            title: "OS X Yosemite",
            version: "10.10",
            build: nil,
            sizeHint: nil,
            source: .legacyDMG(URL(string: "http://updates-http.cdn-apple.com/2019/cert/061-41343-20191023-02465f92-3ab5-4c92-bfe2-b725447a070d/InstallMacOSX.dmg")!),
            note: "下载 DMG 后需打开其中的 PKG，将安装器放入“应用程序”。"
        ),
        InstallerOption(
            id: "legacy-mountain-lion-10.8",
            title: "OS X Mountain Lion",
            version: "10.8",
            build: nil,
            sizeHint: nil,
            source: .legacyDMG(URL(string: "https://updates.cdn-apple.com/2021/macos/031-0627-20210614-90D11F33-1A65-42DD-BBEA-E1D9F43A6B3F/InstallMacOSX.dmg")!),
            note: "下载 DMG 后需打开其中的 PKG，将安装器放入“应用程序”。"
        ),
        InstallerOption(
            id: "legacy-lion-10.7",
            title: "OS X Lion",
            version: "10.7",
            build: nil,
            sizeHint: nil,
            source: .legacyDMG(URL(string: "https://updates.cdn-apple.com/2021/macos/041-7683-20210614-E610947E-C7CE-46EB-8860-D26D71F0D3EA/InstallMacOSX.dmg")!),
            note: "下载 DMG 后需打开其中的 PKG，将安装器放入“应用程序”。"
        )
    ]

    static func mergeInstallers(_ groups: [InstallerOption]...) -> [InstallerOption] {
        var seen = Set<String>()
        var merged: [InstallerOption] = []

        for group in groups {
            for installer in group {
                let key: String
                switch installer.source {
                case .softwareUpdate, .installAssistantPackage:
                    key = "softwareupdate-\(installer.version)"
                case let .legacyDMG(url):
                    key = "legacy-\(url.absoluteString)"
                }

                guard !seen.contains(key) else { continue }
                seen.insert(key)
                merged.append(installer)
            }
        }

        return merged
    }

    static func resolve(_ options: [InstallerOption], with packages: [InstallAssistantPackage]) -> [InstallerOption] {
        let packagesByVersion = Dictionary(uniqueKeysWithValues: packages.map { ($0.version, $0) })
        return options.map { option in
            guard case .softwareUpdate = option.source, let package = packagesByVersion[option.version] else {
                return option
            }
            return option.resolved(with: package)
        }
    }

    static func title(for version: String) -> String {
        if version.hasPrefix("27.") { return "macOS Golden Gate Beta" }
        if version.hasPrefix("26.") { return "macOS Tahoe" }
        if version.hasPrefix("15.") { return "macOS Sequoia" }
        if version.hasPrefix("14.") { return "macOS Sonoma" }
        if version.hasPrefix("13.") { return "macOS Ventura" }
        if version.hasPrefix("12.") { return "macOS Monterey" }
        if version.hasPrefix("11.") { return "macOS Big Sur" }
        if version.hasPrefix("10.15") { return "macOS Catalina" }
        if version.hasPrefix("10.14") { return "macOS Mojave" }
        if version.hasPrefix("10.13") { return "macOS High Sierra" }
        return "macOS"
    }

    static func scanLocalInstallers() -> [LocalInstaller] {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { appURL in
            guard appURL.pathExtension == "app" else { return nil }
            let name = appURL.deletingPathExtension().lastPathComponent
            guard name.localizedCaseInsensitiveContains("macos") || name.localizedCaseInsensitiveContains("os x") else {
                return nil
            }

            let createInstallMedia = appURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("createinstallmedia")

            guard FileManager.default.isExecutableFile(atPath: createInstallMedia.path) else {
                return nil
            }

            let infoURL = appURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist")
            let info = NSDictionary(contentsOf: infoURL) as? [String: Any]
            let version = info?["CFBundleShortVersionString"] as? String
            let displayName = info?["CFBundleDisplayName"] as? String ?? name

            return LocalInstaller(
                id: appURL.path,
                name: displayName,
                appPath: appURL.path,
                createInstallMediaPath: createInstallMedia.path,
                version: version
            )
        }
        .sorted { lhs, rhs in
            lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedDescending
        }
    }

}
