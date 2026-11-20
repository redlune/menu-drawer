import SwiftUI
#if MENU_DRAWER_UPDATER
import Sparkle
#endif

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    #if MENU_DRAWER_UPDATER
    let isConfigured = true
    private var controller: SPUStandardUpdaterController?
    #else
    let isConfigured = false
    #endif

    func start() {
        #if MENU_DRAWER_UPDATER
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        #endif
    }

    func checkForUpdates() {
        #if MENU_DRAWER_UPDATER
        guard canCheckForUpdates else { return }
        NSApp.activate()
        controller?.checkForUpdates(nil)
        #endif
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater
    var beforeCheck: () -> Void = {}

    var body: some View {
        if updater.isConfigured {
            Button("updates.check") {
                beforeCheck()
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
