import SwiftUI

@main
struct MacImageConverterApp: App {
    @StateObject private var workspace = WorkspaceModel()
    @StateObject private var presets = PresetStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
                .environmentObject(presets)
                .frame(minWidth: 1050, minHeight: 690)
        }
        .defaultSize(width: 1280, height: 810)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Images…") { workspace.chooseImages() }
                    .keyboardShortcut("o")
            }
        }
    }
}
