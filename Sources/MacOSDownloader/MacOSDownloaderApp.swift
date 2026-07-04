import SwiftUI

@main
struct MacOSDownloaderApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1080, minHeight: 700)
                .task {
                    await appModel.refreshAll()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("刷新设备与本地安装器") {
                    Task { await appModel.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
