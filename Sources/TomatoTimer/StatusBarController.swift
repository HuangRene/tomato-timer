import AppKit
import Combine

/// Menu bar item: left click shows/hides the tomato, right click (or ⌥-click) opens the menu.
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: FloatingPanelController
    private var cancellable: AnyCancellable?

    init(engine: TimerEngine, panel: FloatingPanelController) {
        self.panel = panel
        super.init()

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        cancellable = engine.$remaining
            .combineLatest(engine.$state, engine.$phase)
            .receive(on: RunLoop.main)
            .sink { [weak self] remaining, state, phase in
                self?.item.button?.title = Self.title(remaining: remaining, state: state, phase: phase)
            }
    }

    private static func title(remaining: TimeInterval, state: RunState, phase: Phase) -> String {
        let icon = phase == .work ? "🍅" : "🌿"
        switch state {
        case .idle where phase == .work: return icon
        case .finished: return "\(icon) ⏰"
        case .paused: return "\(icon) ⏸ \(TimerEngine.format(remaining))"
        default: return "\(icon) \(TimerEngine.format(remaining))"
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            item.menu = makeMenu()
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            panel.toggle()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: panel.isVisible ? "隱藏蕃茄" : "顯示蕃茄",
                                action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "開機時自動啟動", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "結束 TomatoTimer",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func togglePanel() {
        panel.toggle()
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }
}
