import SwiftUI

@main
struct PerfoMaceLauncherApp: App {
    var body: some Scene {
        WindowGroup("PerfoMace Launcher v2") {
            ContentView()
                .frame(minWidth: 1040, minHeight: 680)
                // The launcher uses a deliberately light visual system.
                // Without forcing light mode, teammates on macOS Dark Mode
                // get system light foreground colors on top of our hardcoded
                // light cards/backgrounds, which destroys contrast.
                .preferredColorScheme(.light)
        }
    }
}
