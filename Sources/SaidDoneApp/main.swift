import AppKit

// Menu-bar (accessory) app — no Dock icon, no main window (ARCHITECTURE: App Shell).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
