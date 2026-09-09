import SwiftUI

@main
struct MoodleDownloaderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
