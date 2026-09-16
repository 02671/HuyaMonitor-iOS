import SwiftUI

@main
struct HuyaMonitorApp: App {

    @StateObject private var viewModel = MonitorViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
