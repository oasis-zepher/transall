import SwiftUI

@main
struct TransallApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 760, minHeight: 680)
        .task {
          await model.start()
        }
        .onDisappear {
          model.backend.stop()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1240, height: 820)
  }
}
