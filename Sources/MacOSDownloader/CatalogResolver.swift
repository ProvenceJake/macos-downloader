import Foundation

enum CatalogResolver {
    private static let cache = CatalogPackageCache()

    static func resolve(version: String) async throws -> InstallAssistantPackage {
        if let cachedPackage = await cache.package(for: version) {
            return cachedPackage
        }

        let products = try await loadCatalogProducts()
        for (productID, product) in products {
            guard
                let packageInfo = installAssistantPackageInfo(in: product),
                let metadataURL = metadataURL(in: product),
                let metadata = try? await installAssistantMetadata(from: metadataURL)
            else {
                continue
            }

            let package = InstallAssistantPackage(
                id: productID,
                title: InstallerCatalog.title(for: metadata.version),
                version: metadata.version,
                build: metadata.build,
                sizeBytes: packageInfo.sizeBytes,
                url: packageInfo.url,
                postDate: product["PostDate"] as? Date
            )
            await cache.store(package)

            if metadata.version == version {
                return package
            }
        }

        throw CatalogResolverError.packageNotFound(version)
    }

    static func loadInstallAssistantPackages() async throws -> [InstallAssistantPackage] {
        let products = try await loadCatalogProducts()
        var packages: [InstallAssistantPackage] = []
        for (productID, product) in products {
            guard
                let packageInfo = installAssistantPackageInfo(in: product),
                let metadataURL = metadataURL(in: product)
            else {
                continue
            }

            guard let metadata = try? await installAssistantMetadata(from: metadataURL) else {
                continue
            }

            packages.append(
                InstallAssistantPackage(
                    id: productID,
                    title: InstallerCatalog.title(for: metadata.version),
                    version: metadata.version,
                    build: metadata.build,
                    sizeBytes: packageInfo.sizeBytes,
                    url: packageInfo.url,
                    postDate: product["PostDate"] as? Date
                )
            )
        }

        await cache.store(packages)
        return sortedPackages(packages)
    }

    private static func loadCatalogProducts() async throws -> [(id: String, product: [String: Any])] {
        let catalogData = try await fetchCatalogData()
        guard
            let root = try PropertyListSerialization.propertyList(from: catalogData, options: [], format: nil) as? [String: Any],
            let products = root["Products"] as? [String: Any]
        else {
            throw CatalogResolverError.invalidCatalog
        }

        return products.compactMap { productID, rawProduct in
            guard let product = rawProduct as? [String: Any] else { return nil }
            return (productID, product)
        }
        .sorted { lhs, rhs in
            let leftDate = lhs.product["PostDate"] as? Date ?? .distantPast
            let rightDate = rhs.product["PostDate"] as? Date ?? .distantPast
            return leftDate > rightDate
        }
    }

    private static func sortedPackages(_ packages: [InstallAssistantPackage]) -> [InstallAssistantPackage] {
        packages.sorted { lhs, rhs in
            if compareVersions(lhs.version, rhs.version) == .orderedSame {
                return (lhs.postDate ?? .distantPast) > (rhs.postDate ?? .distantPast)
            }
            return compareVersions(lhs.version, rhs.version) == .orderedDescending
        }
    }

    private static func fetchCatalogData() async throws -> Data {
        let catalogURL = currentCatalogURL()
        let (compressedData, _) = try await URLSession.shared.data(from: catalogURL)

        if compressedData.isGzipData {
            return try gunzip(compressedData)
        }
        return compressedData
    }

    private static func currentCatalogURL() -> URL {
        let plistURL = URL(fileURLWithPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist")
        if
            let dictionary = NSDictionary(contentsOf: plistURL) as? [String: Any],
            let value = dictionary["CatalogURL"] as? String,
            let url = URL(string: value)
        {
            return url
        }

        return URL(string: "https://swscan.apple.com/content/catalogs/others/index-27seed-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz")!
    }

    private static func gunzip(_ data: Data) throws -> Data {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSDownloader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let compressedURL = temporaryDirectory.appendingPathComponent("catalog.sucatalog.gz")
        try data.write(to: compressedURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", compressedURL.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            return output
        }

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw CatalogResolverError.gunzipFailed(errorOutput)
    }

    private static func installAssistantPackageInfo(in product: [String: Any]) -> (url: URL, sizeBytes: Int64)? {
        guard let packages = product["Packages"] as? [[String: Any]] else { return nil }

        for package in packages {
            guard
                let urlString = package["URL"] as? String,
                let url = URL(string: urlString)
            else {
                continue
            }

            let fileName = url.lastPathComponent
            guard fileName == "InstallAssistant.pkg" || fileName == "InstallAssistantAuto.pkg" else {
                continue
            }

            let size = (package["Size"] as? NSNumber)?.int64Value ?? 0
            return (url, size)
        }

        return nil
    }

    private static func metadataURL(in product: [String: Any]) -> URL? {
        guard let packages = product["Packages"] as? [[String: Any]] else { return nil }

        let preferredNames = [
            "com_apple_MobileAsset_MacSoftwareUpdate.plist",
            "Info.plist"
        ]

        for name in preferredNames {
            for package in packages {
                guard
                    let urlString = package["URL"] as? String,
                    let url = URL(string: urlString),
                    url.lastPathComponent == name
                else {
                    continue
                }
                return url
            }
        }

        return nil
    }

    private static func installAssistantMetadata(from url: URL) async throws -> (version: String, build: String) {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CatalogResolverError.invalidMetadata
        }

        if
            let assets = root["Assets"] as? [[String: Any]],
            let asset = assets.first,
            let version = asset["OSVersion"] as? String,
            let build = asset["Build"] as? String
        {
            return (version, build)
        }

        if
            let properties = root["MobileAssetProperties"] as? [String: Any],
            let version = properties["OSVersion"] as? String,
            let build = properties["Build"] as? String
        {
            return (version, build)
        }

        throw CatalogResolverError.invalidMetadata
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}

private extension Data {
    var isGzipData: Bool {
        count >= 2 && self[startIndex] == 0x1f && self[index(after: startIndex)] == 0x8b
    }
}

private actor CatalogPackageCache {
    private var packagesByVersion: [String: InstallAssistantPackage] = [:]

    func package(for version: String) -> InstallAssistantPackage? {
        packagesByVersion[version]
    }

    func store(_ package: InstallAssistantPackage) {
        if let existing = packagesByVersion[package.version],
           (existing.postDate ?? .distantPast) >= (package.postDate ?? .distantPast) {
            return
        }
        packagesByVersion[package.version] = package
    }

    func store(_ packages: [InstallAssistantPackage]) {
        for package in packages {
            store(package)
        }
    }
}

enum CatalogResolverError: LocalizedError {
    case invalidCatalog
    case invalidMetadata
    case gunzipFailed(String)
    case packageNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidCatalog:
            return "无法解析 Apple 软件更新目录。"
        case .invalidMetadata:
            return "无法解析安装器版本信息。"
        case let .gunzipFailed(output):
            return output.isEmpty ? "无法解压 Apple 软件更新目录。" : "无法解压 Apple 软件更新目录：\(output)"
        case let .packageNotFound(version):
            return "没有在 Apple 软件更新目录中找到 macOS \(version) 的 InstallAssistant.pkg。"
        }
    }
}
