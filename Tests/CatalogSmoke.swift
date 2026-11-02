import Foundation

@main
struct CatalogSmoke {
    static func main() async throws {
        let olderDate = Date(timeIntervalSince1970: 1)
        let newerDate = Date(timeIntervalSince1970: 2)
        let packages = [
            package("26.6.2", build: "old", date: newerDate),
            package("26.7", build: "current", date: olderDate),
            package("15.8", build: "first", date: olderDate),
            package("15.8", build: "second", date: newerDate),
            package("14.8.9", build: "sonoma", date: newerDate),
            package("13.7.8", build: "ventura", date: newerDate),
            package("27.0", build: "golden-gate", date: newerDate)
        ]
        let options = InstallerCatalog.latestInstallers(from: packages)
        precondition(Array(options.prefix(5)).map(\.version) == ["27.0", "26.7", "15.8", "14.8.9", "13.7.8"])
        precondition(options[1].build == "current")
        precondition(options[2].build == "second")
        precondition(options[1].id == "modern-26")

        let livePackages = try await CatalogResolver.loadInstallAssistantPackages()
        let liveOptions = InstallerCatalog.latestInstallers(from: livePackages)
        for option in liveOptions.prefix(5) {
            guard case let .installAssistantPackage(url) = option.source else {
                fatalError("Missing full installer for \(option.title)")
            }
            precondition(url.host?.hasSuffix(".apple.com") == true)
            print("\(option.displayTitle) (\(option.build ?? "unknown build"))")
        }
    }

    private static func package(_ version: String, build: String, date: Date) -> InstallAssistantPackage {
        InstallAssistantPackage(
            id: "\(version)-\(build)",
            title: InstallerCatalog.title(for: version),
            version: version,
            build: build,
            sizeBytes: 1,
            url: URL(string: "https://swcdn.apple.com/\(version)/\(build)/InstallAssistant.pkg")!,
            postDate: date
        )
    }
}
