import Foundation

enum CatalogResolver {
    static func resolveLatest(majorVersion: String) async throws -> InstallAssistantPackage {
        guard let package = try await loadInstallAssistantPackages()
            .first(where: { InstallerCatalog.majorVersion(for: $0.version) == majorVersion })
        else {
            throw CatalogResolverError.packageNotFound(majorVersion)
        }
        return package
    }

    static func loadInstallAssistantPackages() async throws -> [InstallAssistantPackage] {
        let products = try await loadCatalogProducts()
        var packages: [InstallAssistantPackage] = []
        for (productID, product) in products {
            guard
                let packageInfo = installAssistantPackageInfo(in: product),
                let distributionURL = distributionURL(in: product)
            else {
                continue
            }

            let metadata = try await installAssistantMetadata(from: distributionURL)

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
        URL(string: "https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz")!
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

        let outputURL = temporaryDirectory.appendingPathComponent("catalog.sucatalog")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let errorPipe = Pipe()
        process.standardOutput = outputHandle
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return try Data(contentsOf: outputURL)
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

    private static func distributionURL(in product: [String: Any]) -> URL? {
        guard let distributions = product["Distributions"] as? [String: String] else { return nil }
        return (distributions["English"] ?? distributions.values.first).flatMap(URL.init(string:))
    }

    private static func installAssistantMetadata(from url: URL) async throws -> (version: String, build: String) {
        let (data, _) = try await URLSession.shared.data(from: url)
        let document = try XMLDocument(data: data, options: [])
        guard let dictionary = try document.nodes(forXPath: "/installer-gui-script/auxinfo/dict").first as? XMLElement else {
            throw CatalogResolverError.invalidMetadata
        }

        let elements = dictionary.children?.compactMap { $0 as? XMLElement } ?? []
        var fields: [String: String] = [:]
        for index in stride(from: 0, to: elements.count, by: 2) {
            guard index + 1 < elements.count,
                  elements[index].name == "key",
                  elements[index + 1].name == "string",
                  let key = elements[index].stringValue,
                  let value = elements[index + 1].stringValue else {
                continue
            }
            fields[key] = value
        }

        if let version = fields["VERSION"], let build = fields["BUILD"] {
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
            return "没有在 Apple 软件更新目录中找到 macOS \(version) 的完整安装器。"
        }
    }
}
