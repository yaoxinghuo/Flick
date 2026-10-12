import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    /// Open requests (Finder "Open With", Dock drop) that arrived before the
    /// window existed.
    private var pendingURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MenuBuilder.makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)

        var urls = pendingURLs
        pendingURLs = []
        if urls.isEmpty {
            urls = ProcessInfo.processInfo.arguments
                .dropFirst()
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if !urls.isEmpty {
            controller.open(urls: urls)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // Finder "Open With" / double-click / Dock drop.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpen([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleOpen(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    private func handleOpen(_ urls: [URL]) {
        if let windowController {
            windowController.open(urls: urls)
            windowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windowController?.showWindow(nil)
        }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
