import SwiftUI

@main
struct VMixerApp: App {
    var body: some Scene {
        // Your Menu Bar setup
        MenuBarExtra("VMixer", systemImage: "slider.horizontal.3") {
            ContentView()
        }
        .menuBarExtraStyle(.window) // Makes it look like a popover widget

        // 🚨 ADD THIS: The Native Settings Window
        Settings {
            SettingsView()
        }
    }
}
