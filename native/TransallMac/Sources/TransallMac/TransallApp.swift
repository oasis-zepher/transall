import AppKit
import SwiftUI

extension Notification.Name {
  static let transallChooseDocuments = Notification.Name("com.transall.mac.choose-documents")
}

@main
struct TransallApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("Transall") {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 760, minHeight: 680)
        .task {
          await model.start()
        }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
          model.prepareForTermination()
        }
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .defaultSize(width: 1240, height: 820)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("选择文件…") {
          NotificationCenter.default.post(name: .transallChooseDocuments, object: nil)
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(!model.canSelectDocuments)
      }
    }

    Settings {
      SettingsView()
        .environmentObject(model)
    }
  }
}
