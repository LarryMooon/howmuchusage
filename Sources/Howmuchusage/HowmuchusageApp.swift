import AppKit
import UsageProviders

@main
enum HowmuchusageMain {
    @MainActor
    static func main() {
        // Claude Code statusline bridge mode: capture rate_limits, print, exit.
        if CommandLine.arguments.contains(StatuslineBridge.launchArgument) {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let output = StatuslineBridge().runBridge(input: input)
            FileHandle.standardOutput.write(output)
            exit(0)
        }

        ProcessRunner.ignoreSIGPIPE()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings?
    private var store: UsageStore?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings()
        let store = UsageStore(settings: settings)
        self.settings = settings
        self.store = store
        statusController = StatusItemController(store: store)
        store.start()

        // A menu-bar-only app has no window; open the popover once so a new
        // user can find it and connect accounts.
        if settings.consumeFirstLaunch() {
            statusController?.showPopoverSoon()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusController?.showPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.shutdown()
    }
}
