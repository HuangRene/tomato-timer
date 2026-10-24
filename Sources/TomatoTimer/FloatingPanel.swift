import AppKit

/// Borderless panel that floats above every app, on every Space and over
/// full-screen apps, without ever taking keyboard focus.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // the tomato draws its own shadow
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Don't let AppKit push the window down out from under the menu bar. Near the top of the
    /// screen the transparent part of the window overlaps the menu bar (which stays above it and
    /// keeps its clicks); if AppKit moved the window, the tomato would be drawn in the wrong spot
    /// and jump when the window changes size.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Owns the panel. Collapsed, the window is just big enough for the small tomato so it
/// doesn't block clicks around it; while the tomato is open or bouncing it grows to a
/// larger square so the jelly overshoot never gets clipped.
final class FloatingPanelController {
    private static let compactSide: CGFloat = 150
    private static let expandedSide: CGFloat = 460
    private static let centerKey = "tomatoCenter"

    private let panel: FloatingPanel
    private let tomatoView: JellyTomatoView
    /// Screen position of the collapsed tomato's center.
    private var anchor: NSPoint

    init(engine: TimerEngine) {
        anchor = Self.savedCenter() ?? Self.defaultCenter()
        let frame = Self.square(around: anchor, side: Self.compactSide)
        panel = FloatingPanel(contentRect: frame)
        tomatoView = JellyTomatoView(engine: engine, frame: NSRect(origin: .zero, size: frame.size))
        tomatoView.autoresizingMask = [.width, .height]
        panel.contentView = tomatoView

        tomatoView.willExpand = { [weak self] in self?.useExpandedWindow() }
        tomatoView.didSettleCollapsed = { [weak self] in self?.useCompactWindow() }
        tomatoView.onDrag = { [weak self] dx, dy in self?.drag(dx: dx, dy: dy) }
        tomatoView.onDragEnded = { [weak self] in self?.dragEnded() }
        useCompactWindow()
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
        tomatoView.needsDisplay = true
        tomatoView.startAnimating()
    }

    func hide() {
        tomatoView.snapCollapsed()
        useCompactWindow()
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    // MARK: - Window sizing

    private func useCompactWindow() {
        place(Self.square(around: anchor, side: Self.compactSide), expanded: anchor)
    }

    private func useExpandedWindow() {
        let expanded = expandedCenter()
        place(Self.square(around: expanded, side: Self.expandedSide), expanded: expanded)
    }

    /// Positions first, then resize and redraw in one go, so no frame shows the old drawing in the
    /// new window. If the window still ends up somewhere else, re-aim at the frame it actually got.
    private func place(_ frame: NSRect, expanded: NSPoint) {
        tomatoView.compactCenter = viewPoint(anchor, in: frame)
        tomatoView.expandedCenter = viewPoint(expanded, in: frame)
        panel.setFrame(frame, display: true)
        let actual = panel.frame
        if actual != frame {
            tomatoView.compactCenter = viewPoint(anchor, in: actual)
            tomatoView.expandedCenter = viewPoint(expanded, in: actual)
        }
    }

    /// The open tomato's center: the collapsed position, nudged so the whole tomato stays on screen.
    private func expandedCenter() -> NSPoint {
        guard let vf = Self.visibleFrame(containing: anchor) else { return anchor }
        let margin = JellyTomatoView.expandedRadius + 16
        return NSPoint(x: min(max(anchor.x, vf.minX + margin), vf.maxX - margin),
                       y: min(max(anchor.y, vf.minY + margin), vf.maxY - margin))
    }

    /// Screen point → the tomato view's flipped coordinates.
    private func viewPoint(_ p: NSPoint, in frame: NSRect) -> CGPoint {
        CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y)
    }

    // MARK: - Dragging

    private func drag(dx: CGFloat, dy: CGFloat) {
        // Move the anchor by how far the window really moved, so the two can never drift apart.
        let before = panel.frame.origin
        panel.setFrameOrigin(NSPoint(x: before.x + dx, y: before.y + dy))
        let after = panel.frame.origin
        anchor.x += after.x - before.x
        anchor.y += after.y - before.y
    }

    private func dragEnded() {
        if let vf = Self.visibleFrame(containing: anchor) {
            let margin = JellyTomatoView.compactRadius + 8
            let clamped = NSPoint(x: min(max(anchor.x, vf.minX + margin), vf.maxX - margin),
                                  y: min(max(anchor.y, vf.minY + margin), vf.maxY - margin))
            if clamped != anchor {
                anchor = clamped
                tomatoView.compactCenter = viewPoint(anchor, in: panel.frame)
            }
        }
        UserDefaults.standard.set([anchor.x, anchor.y], forKey: Self.centerKey)
    }

    // MARK: - Helpers

    private static func square(around center: NSPoint, side: CGFloat) -> NSRect {
        NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    private static func savedCenter() -> NSPoint? {
        let defaults = UserDefaults.standard
        var center: NSPoint?
        if let xy = defaults.array(forKey: centerKey) as? [Double], xy.count == 2 {
            center = NSPoint(x: xy[0], y: xy[1])
        } else if let xy = defaults.array(forKey: "panelOrigin") as? [Double], xy.count == 2 {
            // Position saved by v1 (origin of an 80×80 panel).
            center = NSPoint(x: xy[0] + 40, y: xy[1] + 40)
        }
        guard let center else { return nil }
        return NSScreen.screens.contains { $0.visibleFrame.contains(center) } ? center : nil
    }

    private static func defaultCenter() -> NSPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset = JellyTomatoView.compactRadius + 24
        return NSPoint(x: vf.maxX - inset, y: vf.maxY - inset)
    }

    private static func visibleFrame(containing point: NSPoint) -> NSRect? {
        (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
    }
}
