import AppKit

@main
enum MenuDrawer {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let controller = DrawerController()
        app.delegate = controller
        withExtendedLifetime(controller) {
            app.run()
        }
    }
}
