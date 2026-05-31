import AppKit

// Regular app: Dock icon + main window, plus a menu-bar item. Closing the window keeps it
// running in the menu bar (see AppController.applicationShouldTerminateAfterLastWindowClosed).
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController()
app.delegate = controller
app.run()
