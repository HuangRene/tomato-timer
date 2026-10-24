import AppKit
import Combine

enum Phase {
    case work, rest
}

enum RunState {
    case idle      // full time on the clock, not started
    case running
    case paused
    case finished  // time is up, waiting for the user to click
}

/// Pomodoro state machine. Counts down toward a fixed `endDate` instead of
/// decrementing a counter, so the time stays correct across sleep/wake.
final class TimerEngine: ObservableObject {
    static let presets = [15, 30, 45, 60]
    static let restMinutes = 10
    private static let workMinutesKey = "workMinutes"

    @Published private(set) var phase: Phase = .work
    @Published private(set) var state: RunState = .idle
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var workMinutes: Int

    var onFinish: ((Phase) -> Void)?

    private let secondsPerMinute: TimeInterval
    private var endDate: Date?
    private var ticker: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(secondsPerMinute: TimeInterval = 60) {
        self.secondsPerMinute = secondsPerMinute
        let saved = UserDefaults.standard.integer(forKey: Self.workMinutesKey)
        let minutes = Self.presets.contains(saved) ? saved : 30
        workMinutes = minutes
        remaining = TimeInterval(minutes) * secondsPerMinute

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tick()
        }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var total: TimeInterval {
        TimeInterval(phase == .work ? workMinutes : Self.restMinutes) * secondsPerMinute
    }

    var progress: Double {
        total > 0 ? min(1, max(0, 1 - remaining / total)) : 0
    }

    // MARK: - Actions

    /// Play/pause button.
    func toggle() {
        switch state {
        case .idle, .paused: start()
        case .running: pause()
        case .finished: acknowledge()
        }
    }

    /// Reset the current phase back to its full length, without starting it.
    func reset() {
        stopTicker()
        remaining = total
        state = .idle
    }

    func selectPreset(_ minutes: Int) {
        guard phase == .work || state == .finished else { return }
        let wasRunning = state == .running
        phase = .work
        workMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: Self.workMinutesKey)
        reset()
        if wasRunning { start() }
    }

    /// Clicking the tomato after time is up: work → start the break, break → back to idle work.
    func acknowledge() {
        guard state == .finished else { return }
        switch phase {
        case .work:
            phase = .rest
            remaining = total
            start()
        case .rest:
            phase = .work
            remaining = total
            state = .idle
        }
    }

    // MARK: - Timing

    private func start() {
        stopTicker()
        endDate = Date().addingTimeInterval(remaining)
        state = .running
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func pause() {
        if let endDate { remaining = max(0, endDate.timeIntervalSinceNow) }
        stopTicker()
        state = .paused
    }

    private func tick() {
        guard state == .running, let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left <= 0 {
            finish()
        } else {
            remaining = left
        }
    }

    private func finish() {
        stopTicker()
        remaining = 0
        state = .finished
        onFinish?(phase)
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
