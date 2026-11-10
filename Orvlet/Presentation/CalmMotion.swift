import AppKit
import QuartzCore
import SwiftUI

/// One interruptible clock for native geometry and visibility. New intent starts
/// from the currently displayed frame, never queues behind an old animation.
@MainActor
final class CalmMotionDriver: NSObject {
    private var link: CADisplayLink?
    private var clockTarget: ClockTarget?
    private var update: ((Double) -> Void)?
    private var completion: (() -> Void)?
    private var started: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var revision = 0
    var isRunning: Bool { link != nil }

    // CADisplayLink retains its target; the proxy keeps the driver/window releasable.
    private final class ClockTarget: NSObject {
        weak var owner: CalmMotionDriver?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    deinit { link?.invalidate() }
    func cancel() {
        revision += 1
        link?.invalidate()
        link = nil
        clockTarget = nil
        update = nil
        completion = nil
    }
    func run(
        duration: TimeInterval, window: NSWindow? = nil,
        update: @escaping (Double) -> Void, completion: @escaping () -> Void = {}
    ) {
        cancel()
        guard duration > 0, let screen = window?.screen ?? NSScreen.main else {
            update(1)
            completion()
            return
        }
        self.update = update
        self.completion = completion
        self.duration = duration
        started = CACurrentMediaTime()
        let target = ClockTarget()
        target.owner = self
        clockTarget = target
        let selector = #selector(ClockTarget.tick(_:))
        // A window-scoped link can stop ticking at alpha zero/while occluded,
        // exactly when a newly shown panel needs its first fade-in frame.
        let displayLink = screen.displayLink(target: target, selector: selector)
        link = displayLink
        // Use the owning display's cadence, including ProMotion.
        // Common modes keep animation alive while the user drags or tracks a menu.
        displayLink.add(to: .main, forMode: .common)
    }
    private func tick(_ link: CADisplayLink) {
        guard self.link === link else { return }
        let ticket = revision
        let t = max(0, min(1, (CACurrentMediaTime() - started) / duration))
        // Zero velocity at both ends: a quiet departure and a soft, exact landing.
        update?(t * t * t * (t * (6 * t - 15) + 10))
        guard ticket == revision else { return }
        if t >= 1 {
            let finished = completion
            cancel()
            finished?()
        }
    }
}

@MainActor
enum CalmMotion {
    static let expand: TimeInterval = 0.32
    static let collapse: TimeInterval = 0.26
    static let content: TimeInterval = 0.20
    static func animation(reduced: Bool) -> Animation? {
        reduced ? nil : .easeInOut(duration: content)
    }
    static func layout(reduced: Bool) -> Animation? {
        reduced ? nil : .smooth(duration: 0.32, extraBounce: 0)
    }
    static func response(reduced: Bool, pressed: Bool = false) -> Animation? {
        reduced ? nil : .easeOut(duration: pressed ? 0.09 : 0.18)
    }
    static func blend(_ a: NSRect, _ b: NSRect, _ t: Double) -> NSRect {
        NSRect(
            x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}

private struct CalmReducedMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var calmReducedMotion: Bool {
        get { self[CalmReducedMotionKey.self] }
        set { self[CalmReducedMotionKey.self] = newValue }
    }
}
