import AppKit
import SwiftUI

@main
struct TransallApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .preferredColorScheme(.light)
        .frame(minWidth: 760, minHeight: 680)
        .task {
          await model.start()
        }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
          model.backend.prepareForTermination()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1240, height: 820)

    Settings {
      SettingsView()
        .environmentObject(model)
        .preferredColorScheme(.light)
    }
  }
}
