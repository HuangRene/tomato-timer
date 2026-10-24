import AppKit

@main
enum TomatoTimerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // `--fast` makes one "minute" last one second, for testing the whole flow quickly.
    private let engine = TimerEngine(secondsPerMinute: CommandLine.arguments.contains("--fast") ? 1 : 60)
    private var panel: FloatingPanelController!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanelController(engine: engine)
        statusBar = StatusBarController(engine: engine, panel: panel)

        engine.onFinish = { [weak self] phase in
            SoundPlayer.playAlert(for: phase)
            self?.panel.show()
        }

        LoginItem.enableOnFirstLaunch()

        // Testing aids: `--show` opens the tomato at launch, `--start` starts the countdown.
        let args = CommandLine.arguments
        if args.contains("--show") { panel.show() }
        if args.contains("--start") { engine.toggle() }
    }
}
