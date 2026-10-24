import Foundation
import ServiceManagement

enum LoginItem {
    private static let didSetUpKey = "didSetUpLoginItem"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("TomatoTimer: could not update login item: \(error)")
        }
    }

    /// Turns on launch-at-login the first time the app runs from /Applications.
    /// After that the menu toggle is the source of truth.
    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !defaults.bool(forKey: didSetUpKey) else { return }
        defaults.set(true, forKey: didSetUpKey)
        setEnabled(true)
    }
}
