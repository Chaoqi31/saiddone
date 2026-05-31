import ServiceManagement

/// Start-at-login via SMAppService (macOS 13+).
enum LoginItem {
    static func apply(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            slog("login item apply(\(enabled)) failed: \(error)")
        }
    }
}
