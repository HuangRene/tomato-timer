import AppKit
import Combine

/// The jelly tomato, drawn and animated by hand. Port of prototype/jelly-tomato.html:
/// a spring for the size (collapsed ↔ cut open), a squash/stretch wobble, and 48 coupled
/// surface points for ripples. Geometry is in "units" where the tomato's radius is 125.
final class JellyTomatoView: NSView {
    static let compactRadius: CGFloat = 40
    static let expandedRadius: CGFloat = 136

    /// Where the tomato sits collapsed / expanded, in this view's (flipped) coordinates.
    var compactCenter = CGPoint.zero { didSet { needsDisplay = true } }
    var expandedCenter = CGPoint.zero { didSet { needsDisplay = true } }
    /// Called before growing, so the window can be enlarged first.
    var willExpand: (() -> Void)?
    /// Called once the collapse has fully settled, so the window can shrink back.
    var didSettleCollapsed: (() -> Void)?
    /// Drag deltas in screen points (y up).
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private let engine: TimerEngine
    private var cancellable: AnyCancellable?

    // MARK: Physics

    private struct Spring {
        var x: CGFloat = 0
        var v: CGFloat = 0

        mutating func step(to target: CGFloat, k: CGFloat, c: CGFloat, h: CGFloat) {
            v += (k * (target - x) - c * v) * h
            x += v * h
        }

        func isSettled(at target: CGFloat) -> Bool { abs(x - target) < 0.002 && abs(v) < 0.01 }
    }

    private struct SurfacePoint {
        let a: CGFloat
        let base: CGFloat
        var d: CGFloat = 0
        var v: CGFloat = 0
        var acc: CGFloat = 0
    }

    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    // Damping 12.9 → ~14% overshoot; AMP 0.7 → every kick 30% softer than the first prototype.
    private let kSize: CGFloat = 150
    private lazy var cSize: CGFloat = reduceMotion ? 2 * sqrt(150) : 12.9
    private let kWobble: CGFloat = 230
    private lazy var cWobble: CGFloat = reduceMotion ? 40 : 9
    private let kSurface: CGFloat = 260, cSurface: CGFloat = 9, coupling: CGFloat = 160
    private lazy var amp: CGFloat = reduceMotion ? 0.25 : 0.7
    // Hover pops: a little overshoot, like cubic-bezier(0.34, 1.56, 0.64, 1).
    private let kPop: CGFloat = 320, cPop: CGFloat = 21

    private var size = Spring()
    private var sizeTarget: CGFloat = 0
    private var wobble = Spring()
    private var surface: [SurfacePoint]
    private var locHover = [Spring](repeating: Spring(), count: 4)
    private var locPress = [Spring](repeating: Spring(), count: 4)
    private var btnHover = [Spring](repeating: Spring(), count: 2)
    private var btnPress = [Spring](repeating: Spring(), count: 2)
    private var restMix: CGFloat = 0

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var nextJiggle: CFTimeInterval = 0
    private var wasFinished = false
    private var bigWindow = false

    // MARK: Pointer state

    private enum Target: Equatable {
        case locule(Int), play, reset
    }

    private var hovering = false
    private var hoverTarget: Target?
    private var pressTarget: Target?
    private var collapseWork: DispatchWorkItem?
    private var lastLocal: CGPoint?
    private var dragStart: NSPoint?
    private var lastDragPoint: NSPoint?
    private var dragging = false

    // Last drawn transform, for hit testing.
    private var drawnCenter = CGPoint.zero
    private var drawnSX: CGFloat = 0.32
    private var drawnSY: CGFloat = 0.32

    // MARK: Geometry (units)

    private struct Locule {
        let minutes: Int
        let mid: CGFloat
        let hover: NSColor
        let path: CGPath
        let center: CGPoint
        let label: CGPoint
        let seeds: [(point: CGPoint, angle: CGFloat)]
    }

    private static let locules: [Locule] = {
        let specs: [(Int, CGFloat, NSColor)] = [
            (15, 225, NSColor(hex: 0xFFC23C)),
            (30, 315, NSColor(hex: 0xFF7FA8)),
            (45, 45, NSColor(hex: 0xFF9638)),
            (60, 135, NSColor(hex: 0xA97BFF)),
        ]
        return specs.map { minutes, midDeg, hover in
            let mid = midDeg * .pi / 180
            let a0 = mid - .pi / 4, a1 = mid + .pi / 4
            let rO: CGFloat = 98, rI: CGFloat = 66, gap: CGFloat = 12
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: rO, startAngle: a0 + gap / rO, endAngle: a1 - gap / rO, clockwise: false)
            path.addArc(center: .zero, radius: rI, startAngle: a1 - gap / rI, endAngle: a0 + gap / rI, clockwise: true)
            path.closeSubpath()
            let seedSpots: [(CGFloat, CGFloat)] = [(94, -0.5), (94, -0.24), (94, 0.24), (94, 0.5), (70, -0.42), (70, 0.42)]
            let seeds = seedSpots.map { r, off in (point: polar(r, mid + off), angle: mid + off + .pi / 2) }
            return Locule(minutes: minutes, mid: mid, hover: hover, path: path,
                          center: polar(82, mid), label: polar(80, mid), seeds: seeds)
        }
    }()

    private static let buttonCenters = [CGPoint(x: -17, y: 31), CGPoint(x: 17, y: 31)]

    private static let calyxPath: CGPath = {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: -2.5, y: 2), CGPoint(x: -2, y: -12), CGPoint(x: 2.5, y: -13), CGPoint(x: 2.5, y: 2)])
        p.closeSubpath()
        for k in 0..<5 {
            let a = CGFloat(-54 + 72 * k) * .pi / 180
            let len: CGFloat = (1...3).contains(k) ? 19 : 23
            let tip = CGPoint(x: len * cos(a), y: len * sin(a) * 0.55)
            p.move(to: .zero)
            p.addQuadCurve(to: tip, control: polar(11, a - 0.42))
            p.addQuadCurve(to: .zero, control: polar(11, a + 0.42))
            p.closeSubpath()
        }
        return p
    }()

    private static func baseRadius(_ a: CGFloat) -> CGFloat {
        let t = atan2(sin(a + .pi / 2), cos(a + .pi / 2))
        return 125 - 3.5 * cos(4 * a) - 8 * exp(-(t * t) / 0.05)
    }

    // MARK: Palette

    private struct Palette {
        let skinA, skinB, gel, gelSelected, coreA, coreB, ink, calyx: NSColor
    }

    private static let workPalette = Palette(
        skinA: NSColor(hex: 0xFF6A55), skinB: NSColor(hex: 0xD9261B),
        gel: NSColor(hex: 0xFF8E78), gelSelected: NSColor(hex: 0xFFB4A3),
        coreA: NSColor(hex: 0xFFE3DA), coreB: NSColor(hex: 0xFFC2B1),
        ink: NSColor(hex: 0x7A1D14), calyx: NSColor(hex: 0x2F8F3A))
    private static let restPalette = Palette(
        skinA: NSColor(hex: 0x6FD173), skinB: NSColor(hex: 0x2E9A3E),
        gel: NSColor(hex: 0xA8E99A), gelSelected: NSColor(hex: 0xA8E99A),
        coreA: NSColor(hex: 0xEEFBE6), coreB: NSColor(hex: 0xCDEFC0),
        ink: NSColor(hex: 0x1F5A28), calyx: NSColor(hex: 0x1E5E27))
    private static let buttonHoverColors = [NSColor(hex: 0x43D693), NSColor(hex: 0x5BB8FF)]

    // MARK: Init

    init(engine: TimerEngine, frame: NSRect) {
        self.engine = engine
        surface = (0..<48).map { i in
            let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 48
            return SurfacePoint(a: a, base: Self.baseRadius(a))
        }
        super.init(frame: frame)
        restMix = engine.phase == .rest ? 1 : 0
        wasFinished = engine.state == .finished
        cancellable = engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.engineChanged() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Public control

    func setExpanded(_ expanded: Bool) {
        let target: CGFloat = expanded ? 1 : 0
        guard sizeTarget != target else { return }
        if expanded && !bigWindow {
            bigWindow = true
            willExpand?()
        }
        sizeTarget = target
        wobble.v += (expanded ? 3.2 : -2.6) * amp
        kickRipple(expanded ? 55 : 35, lobes: expanded ? 3 : 4)
        startAnimating()
    }

    /// Jump straight to the collapsed, resting state (used when the panel is hidden).
    func snapCollapsed() {
        collapseWork?.cancel()
        hovering = false
        hoverTarget = nil
        sizeTarget = 0
        size = Spring()
        wobble = Spring()
        for i in surface.indices { surface[i].d = 0; surface[i].v = 0 }
        bigWindow = false
        stopAnimating()
        needsDisplay = true
    }

    func startAnimating() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    private func engineChanged() {
        let finished = engine.state == .finished
        if finished && !wasFinished { nextJiggle = 0 }
        wasFinished = finished
        needsDisplay = true
        startAnimating()
    }

    private func kickRipple(_ strength: CGFloat, lobes: CGFloat) {
        let phase = CGFloat.random(in: 0..<(2 * .pi))
        for i in surface.indices {
            surface[i].v += strength * amp * sin(lobes * surface[i].a + phase)
        }
    }

    // MARK: Animation loop

    private var detail: CGFloat { min(1, max(0, (size.x - 0.35) / 0.5)) }
    private var isInteractive: Bool { detail > 0.6 && engine.state != .finished }

    private func tick() {
        guard window?.isVisible == true else { stopAnimating(); return }
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.033, now - lastTick))
        lastTick = now

        let h = dt / 3
        let breathing = !reduceMotion && size.x > 0.3
        for _ in 0..<3 {
            size.step(to: sizeTarget, k: kSize, c: cSize, h: h)
            wobble.step(to: 0, k: kWobble, c: cWobble, h: h)
            let n = surface.count
            for i in 0..<n {
                let p = surface[i]
                let prev = surface[(i + n - 1) % n].d, next = surface[(i + 1) % n].d
                let breath: CGFloat = breathing ? 0.9 * sin(CGFloat(now) * 1.8 + p.a * 2) : 0
                surface[i].acc = -kSurface * (p.d - breath) - cSurface * p.v + coupling * (prev + next - 2 * p.d)
            }
            for i in 0..<n {
                surface[i].v += surface[i].acc * h
                surface[i].d = min(18, max(-18, surface[i].d + surface[i].v * h))
            }
        }

        // The tomato moves and grows under a still pointer, so re-check hover from the real
        // pointer position every frame instead of waiting for a mouse event.
        if let pt = currentPointer() {
            let inside = pointerInside(pt)
            if inside != hovering { setHovering(inside) }
            hoverTarget = inside ? hitTarget(localPoint(pt)) : nil
        }

        // Hover / press pops on the chambers and buttons.
        for i in 0..<4 {
            let hovered = isInteractive && engine.phase == .work && hoverTarget == .locule(i)
            locHover[i].step(to: hovered ? 1 : 0, k: kPop, c: cPop, h: dt)
            locPress[i].step(to: pressTarget == .locule(i) && hovered ? 1 : 0, k: kPop * 2, c: cPop * 1.4, h: dt)
        }
        for (i, target) in [Target.play, Target.reset].enumerated() {
            let hovered = isInteractive && hoverTarget == target
            btnHover[i].step(to: hovered ? 1 : 0, k: kPop, c: cPop, h: dt)
            btnPress[i].step(to: pressTarget == target && hovered ? 1 : 0, k: kPop * 2, c: cPop * 1.4, h: dt)
        }

        let restTarget: CGFloat = engine.phase == .rest ? 1 : 0
        restMix += max(-dt / 0.6, min(dt / 0.6, restTarget - restMix))

        if engine.state == .finished && now > nextJiggle {
            nextJiggle = now + 1.1
            wobble.v += (Bool.random() ? 5 : -5) * amp
            kickRipple(80, lobes: CGFloat(Int.random(in: 3...5)))
        }

        needsDisplay = true

        if bigWindow && sizeTarget == 0 && size.isSettled(at: 0) {
            bigWindow = false
            size = Spring()
            didSettleCollapsed?()
        }
        if isAtRest() { stopAnimating() }
    }

    private func isAtRest() -> Bool {
        guard sizeTarget == 0, !bigWindow, !hovering, engine.state != .finished,
              wobble.isSettled(at: 0), restMix == (engine.phase == .rest ? 1 : 0) else { return false }
        let springs = locHover + locPress + btnHover + btnPress
        return springs.allSatisfy { $0.isSettled(at: 0) }
            && surface.allSatisfy { abs($0.d) < 0.05 && abs($0.v) < 0.05 }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved(event) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }

    override func mouseExited(with event: NSEvent) {
        // Resizing the window can send a stray exit while the pointer is still on the tomato.
        if let pt = currentPointer(), pointerInside(pt) { return }
        lastLocal = nil
        hoverTarget = nil
        setHovering(false)
    }

    private func currentPointer() -> CGPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// View point → tomato units, using the transform of the last drawn frame.
    private func localPoint(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: (pt.x - drawnCenter.x) / drawnSX, y: (pt.y - drawnCenter.y) / drawnSY)
    }

    private func toLocal(_ event: NSEvent) -> CGPoint {
        localPoint(convert(event.locationInWindow, from: nil))
    }

    /// The hover zone. While open (or opening) it also keeps the spot where the small tomato was:
    /// near a screen edge the open tomato slides inward, away from the pointer that opened it,
    /// and without this it would close, reopen under the pointer, and close again, over and over.
    private func pointerInside(_ pt: CGPoint) -> Bool {
        let local = localPoint(pt)
        if hypot(local.x, local.y) < 130 { return true }
        guard sizeTarget == 1 else { return false }
        return hypot(pt.x - expandedCenter.x, pt.y - expandedCenter.y) < Self.expandedRadius * 1.04
            || hypot(pt.x - compactCenter.x, pt.y - compactCenter.y) < Self.compactRadius * 1.15
    }

    private func pointerMoved(_ event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let local = localPoint(pt)
        let r = hypot(local.x, local.y)
        let inside = pointerInside(pt)
        setHovering(inside)
        hoverTarget = inside ? hitTarget(local) : nil

        // Running the pointer across the rim pushes ripples into the surface.
        if inside, let last = lastLocal, r > 80 {
            let speed = min(30, hypot(local.x - last.x, local.y - last.y))
            let a = atan2(local.y, local.x)
            for i in surface.indices {
                let diff = abs(atan2(sin(surface[i].a - a), cos(surface[i].a - a)))
                if diff < 0.6 { surface[i].v -= speed * 2.2 * amp * (1 - diff / 0.6) }
            }
        }
        lastLocal = local
        startAnimating()
    }

    private func setHovering(_ on: Bool) {
        if on {
            collapseWork?.cancel()
            hovering = true
            setExpanded(true)
        } else if hovering {
            hovering = false
            collapseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, !self.dragging else { return }
                if let pt = self.currentPointer(), self.pointerInside(pt) {
                    self.hovering = true
                    return
                }
                self.setExpanded(false)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    private func hitTarget(_ local: CGPoint) -> Target? {
        guard isInteractive else { return nil }
        for (i, c) in Self.buttonCenters.enumerated() where hypot(local.x - c.x, local.y - c.y) < 14 {
            return i == 0 ? .play : .reset
        }
        guard engine.phase == .work else { return nil }
        let r = hypot(local.x, local.y)
        guard r > 58, r < 106 else { return nil }
        let a = atan2(local.y, local.x)
        if a < -.pi / 2 { return .locule(0) }
        if a < 0 { return .locule(1) }
        if a < .pi / 2 { return .locule(2) }
        return .locule(3)
    }

    override func mouseDown(with event: NSEvent) {
        let local = toLocal(event)
        guard hypot(local.x, local.y) < 130 else { return }
        dragStart = NSEvent.mouseLocation
        lastDragPoint = dragStart
        dragging = false
        pressTarget = hitTarget(local)
        wobble.v -= 2.2 * amp
        startAnimating()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let last = lastDragPoint else { return }
        let m = NSEvent.mouseLocation
        if !dragging && hypot(m.x - start.x, m.y - start.y) > 3 {
            dragging = true
            pressTarget = nil
        }
        if dragging {
            onDrag?(m.x - last.x, m.y - last.y)
            lastDragPoint = m
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        wobble.v += 1.6 * amp
        if dragging {
            dragging = false
            onDragEnded?()
        } else {
            activate(pressTarget)
        }
        pressTarget = nil
        startAnimating()
    }

    private func activate(_ target: Target?) {
        if engine.state == .finished {
            engine.acknowledge()
            wobble.v -= 4 * amp
            kickRipple(70, lobes: 5)
            return
        }
        guard size.x >= 0.6 else { return }
        switch target {
        case .play:
            engine.toggle()
            wobble.v += 2 * amp
        case .reset:
            engine.reset()
            wobble.v -= 2.5 * amp
            kickRipple(30, lobes: 2)
        case .locule(let i):
            guard engine.phase == .work else { return }
            engine.selectPreset(Self.locules[i].minutes)
            kickRipple(45, lobes: 4)
        case nil:
            break
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pal = currentPalette()
        let p = size.x
        let e = detail
        // Shrinking back undershoots below the small size; keep that dip gentle so it doesn't read as a flash.
        let radius = Self.compactRadius + (Self.expandedRadius - Self.compactRadius) * (p < 0 ? p * 0.4 : p)
        let s = radius / 125
        let w = min(0.32, max(-0.32, wobble.x))
        let sx = s * (1 + w), sy = s * (1 - w * 0.9)
        let t = min(1, max(0, p))
        let center = CGPoint(x: compactCenter.x + (expandedCenter.x - compactCenter.x) * t,
                             y: compactCenter.y + (expandedCenter.y - compactCenter.y) * t)
        drawnCenter = center
        drawnSX = sx
        drawnSY = sy

        drawShadow(ctx, center: CGPoint(x: center.x, y: center.y + sy * 125 + 8),
                   rx: sx * 125 * 0.85, ry: 10 + 6 * p)

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: sx, y: sy)

        // Skin
        let bodyPath = makeBodyPath()
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        drawRadialGradient(ctx, colors: [pal.skinA, pal.skinB], center: CGPoint(x: -31, y: -52), radius: 193)
        ctx.restoreGState()
        ctx.addPath(bodyPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()

        // Cut-open view, only while expanded.
        if e > 0.01 {
            ctx.setAlpha(e)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawSlice(ctx, pal: pal)
            ctx.endTransparencyLayer()
            ctx.setAlpha(1)
        }

        // Gloss
        ctx.saveGState()
        ctx.translateBy(x: -58, y: -72)
        ctx.rotate(by: -38 * .pi / 180)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.42).cgColor)
        ctx.fillEllipse(in: CGRect(x: -30, y: -11, width: 60, height: 22))
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: -92, y: -34, width: 12, height: 8))

        // Calyx, riding on the top surface point.
        let top = surface[0]
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -(top.base + top.d) + 4)
        ctx.scaleBy(x: 1 + w * 0.6, y: 1 - w * 0.6)
        ctx.addPath(Self.calyxPath)
        ctx.setFillColor(pal.calyx.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        if e < 0.99 { drawCompactText(alpha: 1 - e) }
        if e > 0.01 { drawCoreUI(ctx, pal: pal, alpha: e) }

        ctx.restoreGState()
    }

    private func currentPalette() -> Palette {
        let a = Self.workPalette, b = Self.restPalette, t = restMix
        return Palette(skinA: a.skinA.mixed(b.skinA, t), skinB: a.skinB.mixed(b.skinB, t),
                       gel: a.gel.mixed(b.gel, t), gelSelected: a.gelSelected.mixed(b.gelSelected, t),
                       coreA: a.coreA.mixed(b.coreA, t), coreB: a.coreB.mixed(b.coreB, t),
                       ink: a.ink.mixed(b.ink, t), calyx: a.calyx.mixed(b.calyx, t))
    }

    private func makeBodyPath() -> CGPath {
        let pts = surface.map { q -> CGPoint in
            let r = q.base + q.d
            return CGPoint(x: r * cos(q.a) * 1.035, y: r * sin(q.a))
        }
        let n = pts.count
        let path = CGMutablePath()
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i + n - 1) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    private func drawSlice(_ ctx: CGContext, pal: Palette) {
        let now = CGFloat(CACurrentMediaTime())
        let isWork = engine.phase == .work
        let labelAlpha = 1 - restMix

        for (i, loc) in Self.locules.enumerated() {
            let hover = min(1, max(0, locHover[i].x))
            let selected = isWork && loc.minutes == engine.workMinutes
            let scale = 1 + 0.07 * locHover[i].x - 0.06 * locPress[i].x
            ctx.saveGState()
            ctx.translateBy(x: loc.center.x, y: loc.center.y)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -loc.center.x, y: -loc.center.y)

            let gel = (selected ? pal.gelSelected : pal.gel).mixed(loc.hover, hover)
            ctx.addPath(loc.path)
            ctx.setFillColor(gel.cgColor)
            ctx.setStrokeColor(gel.cgColor)
            ctx.setLineWidth(12)
            ctx.setLineJoin(.round)
            ctx.drawPath(using: .fillStroke)

            for (k, seed) in loc.seeds.enumerated() {
                let wiggle = reduceMotion ? 0 : hover * 14 * .pi / 180 * sin(now * 2 * .pi + CGFloat(k) * 0.8)
                ctx.saveGState()
                ctx.translateBy(x: seed.point.x, y: seed.point.y)
                ctx.rotate(by: seed.angle + wiggle)
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
                ctx.fillEllipse(in: CGRect(x: -7.2, y: -7.2, width: 14.4, height: 14.4))
                let seedRect = CGRect(x: -3.3, y: -5.4, width: 6.6, height: 10.8)
                ctx.setFillColor(NSColor(hex: 0xF8E7A8).cgColor)
                ctx.fillEllipse(in: seedRect)
                ctx.setStrokeColor(NSColor(hex: 0xE0B65A).cgColor)
                ctx.setLineWidth(0.8)
                ctx.strokeEllipse(in: seedRect)
                ctx.restoreGState()
            }

            if labelAlpha > 0.01 {
                let ink = pal.ink.mixed(.white, hover)
                drawText("\(loc.minutes)", size: 24, weight: selected ? .bold : .semibold,
                         color: ink.withAlphaComponent(labelAlpha), center: CGPoint(x: loc.label.x, y: loc.label.y - 4))
                drawText("分", size: 9, weight: .medium,
                         color: ink.withAlphaComponent(0.75 * labelAlpha), center: CGPoint(x: loc.label.x, y: loc.label.y + 14))
                if selected {
                    ctx.setFillColor(pal.ink.withAlphaComponent(0.8 * labelAlpha).cgColor)
                    ctx.fillEllipse(in: CGRect(x: loc.label.x - 2.4, y: loc.label.y - 26.4, width: 4.8, height: 4.8))
                }
            }
            ctx.restoreGState()
        }

        // Core (columella) with faint radial streaks.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: -54, y: -54, width: 108, height: 108))
        ctx.clip()
        drawRadialGradient(ctx, colors: [pal.coreA, pal.coreB], center: CGPoint(x: -5.4, y: -10.8), radius: 65)
        ctx.restoreGState()
        ctx.setStrokeColor(pal.ink.withAlphaComponent(0.07).cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        for i in 0..<8 {
            let end = polar(48, CGFloat(i) * .pi / 4 + .pi / 8)
            ctx.move(to: .zero)
            ctx.addLine(to: end)
        }
        ctx.strokePath()
    }

    private static let statusLabels: [Phase: [RunState: String]] = [
        .work: [.idle: "準備專注", .running: "專注中", .paused: "已暫停", .finished: "工作完成！"],
        .rest: [.idle: "休息時間", .running: "休息中", .paused: "休息暫停", .finished: "休息結束"],
    ]

    private func drawCompactText(alpha: CGFloat) {
        let stroke = NSColor(red: 120 / 255, green: 18 / 255, blue: 10 / 255, alpha: 0.35 * alpha)
        if engine.state == .finished {
            let isWork = engine.phase == .work
            drawText(isWork ? "時間到" : "休息完", size: 44, weight: .bold,
                     color: .white.withAlphaComponent(alpha), center: CGPoint(x: 0, y: -9), stroke: stroke)
            drawText(isWork ? "點我休息" : "點我繼續", size: 24, weight: .bold,
                     color: .white.withAlphaComponent(alpha), center: CGPoint(x: 0, y: 34), stroke: stroke)
        } else {
            let a = alpha * (engine.state == .running ? 1 : 0.8)
            drawText(TimerEngine.format(engine.remaining), size: 60, weight: .bold,
                     color: .white.withAlphaComponent(a), center: .zero, stroke: stroke, monospacedDigits: true)
        }
    }

    private func drawCoreUI(_ ctx: CGContext, pal: Palette, alpha: CGFloat) {
        let ink = pal.ink
        let status = Self.statusLabels[engine.phase]?[engine.state] ?? ""
        drawText(status, size: 10, weight: .semibold, color: ink.withAlphaComponent(0.8 * alpha),
                 center: CGPoint(x: 0, y: -30.5))

        if engine.state == .finished {
            let isWork = engine.phase == .work
            drawText(isWork ? "時間到！" : "休息完！", size: 22, weight: .bold,
                     color: ink.withAlphaComponent(alpha), center: .zero)
            drawText(isWork ? "點一下開始休息" : "點一下回到工作", size: 10, weight: .semibold,
                     color: ink.withAlphaComponent(0.8 * alpha), center: CGPoint(x: 0, y: 31.5))
            return
        }

        drawText(TimerEngine.format(engine.remaining), size: 30, weight: .bold,
                 color: ink.withAlphaComponent(alpha), center: .zero, monospacedDigits: true)

        for i in 0..<2 {
            let c = Self.buttonCenters[i]
            let hover = min(1, max(0, btnHover[i].x))
            let scale = 1 + 0.18 * btnHover[i].x - 0.14 * btnPress[i].x
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.scaleBy(x: scale, y: scale)
            let bg = NSColor.white.withAlphaComponent(0.7).mixed(Self.buttonHoverColors[i], hover)
            ctx.setFillColor(bg.withAlphaComponent(bg.alphaComponent * alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: -12, y: -12, width: 24, height: 24))
            let icon = ink.mixed(.white, hover).withAlphaComponent(alpha)
            if i == 0 {
                drawPlayPauseIcon(ctx, color: icon, running: engine.state == .running)
            } else {
                drawResetIcon(ctx, color: icon)
            }
            ctx.restoreGState()
        }
    }

    private func drawPlayPauseIcon(_ ctx: CGContext, color: NSColor, running: Bool) {
        ctx.setFillColor(color.cgColor)
        if running {
            ctx.fill(CGRect(x: -5, y: -6, width: 3.6, height: 12))
            ctx.fill(CGRect(x: 1.4, y: -6, width: 3.6, height: 12))
        } else {
            ctx.move(to: CGPoint(x: -3.5, y: -6))
            ctx.addLine(to: CGPoint(x: 6.5, y: 0))
            ctx.addLine(to: CGPoint(x: -3.5, y: 6))
            ctx.closePath()
            ctx.fillPath()
        }
    }

    private func drawResetIcon(_ ctx: CGContext, color: NSColor) {
        // An arc from the top, round clockwise, with the arrowhead at the top pointing left.
        let r: CGFloat = 5.6
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(2.2)
        ctx.setLineCap(.round)
        for k in 0...24 {
            let a = -CGFloat.pi / 2 + CGFloat(k) / 24 * (290 * .pi / 180)
            let pt = polar(r, a)
            k == 0 ? ctx.move(to: pt) : ctx.addLine(to: pt)
        }
        ctx.strokePath()
        ctx.setFillColor(color.cgColor)
        ctx.move(to: CGPoint(x: -3.4, y: -r))
        ctx.addLine(to: CGPoint(x: 1.2, y: -r - 3.4))
        ctx.addLine(to: CGPoint(x: 1.2, y: -r + 3.4))
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawShadow(_ ctx: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: rx, y: ry)
        let color = NSColor(hex: 0x5A0E08).mixed(NSColor(hex: 0x123D18), restMix)
        drawRadialGradient(ctx, colors: [color.withAlphaComponent(0.28), color.withAlphaComponent(0)],
                           center: .zero, radius: 1, extend: false)
        ctx.restoreGState()
    }

    private func drawRadialGradient(_ ctx: CGContext, colors: [NSColor], center: CGPoint, radius: CGFloat, extend: Bool = true) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                               options: extend ? [.drawsAfterEndLocation] : [])
    }

    // MARK: Text

    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let mono: Bool
    }

    private static var fontCache: [FontKey: NSFont] = [:]

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight, monospacedDigits: Bool) -> NSFont {
        let key = FontKey(size: size, weight: weight.rawValue, mono: monospacedDigits)
        if let font = fontCache[key] { return font }
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        descriptor = descriptor.withDesign(.rounded) ?? descriptor
        if monospacedDigits {
            descriptor = descriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]])
        }
        let font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        fontCache[key] = font
        return font
    }

    /// Draws `string` centered on `center` (units). With `stroke`, an outline is painted behind the fill.
    private func drawText(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                          center: CGPoint, stroke: NSColor? = nil, monospacedDigits: Bool = false) {
        let font = Self.roundedFont(size: size, weight: weight, monospacedDigits: monospacedDigits)
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let textSize = text.size()
        let origin = CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2)
        if let stroke {
            NSAttributedString(string: string, attributes: [.font: font, .strokeColor: stroke, .strokeWidth: 7])
                .draw(at: origin)
        }
        text.draw(at: origin)
    }
}

// MARK: - Helpers

private func polar(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
    CGPoint(x: r * cos(a), y: r * sin(a))
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// Linear blend toward `other` in sRGB, `t` in 0...1.
    func mixed(_ other: NSColor, _ t: CGFloat) -> NSColor {
        let t = min(1, max(0, t))
        guard t > 0 else { return self }
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
    }
}
