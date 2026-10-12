import Foundation
import Testing
@testable import FlickCore

struct SwipeTrackerTests {

    private func makeTracker(viewport: Double = 1000) -> SwipeTracker {
        var t = SwipeTracker()
        t.viewportWidth = viewport   // threshold = 150
        return t
    }

    /// Feeds a sequence of uniform horizontal steps and returns the outputs.
    private func drag(_ tracker: inout SwipeTracker, dx: Double, steps: Int, dt: Double = 0.016, start: TimeInterval = 0) -> [SwipeTracker.Output] {
        var outputs: [SwipeTracker.Output] = []
        var t = start
        for _ in 0..<steps {
            outputs.append(tracker.handle(.changed(dx: dx, dy: 0, at: t)))
            t += dt
        }
        return outputs
    }

    @Test func horizontalDragEmitsOffsets() {
        var tracker = makeTracker()
        _ = tracker.handle(.began)
        let outputs = drag(&tracker, dx: -10, steps: 3)
        #expect(outputs[2] == .drag(-30))
        #expect(tracker.state == .horizontal)
    }

    @Test func thresholdCrossTriggersMidGesture() {
        var tracker = makeTracker()
        _ = tracker.handle(.began)
        let outputs = drag(&tracker, dx: -40, steps: 4) // crosses 150 at step 4
        #expect(outputs[3] == .trigger(.next))
        // After triggering, further input is ignored until a new began.
        let extra = tracker.handle(.changed(dx: -40, dy: 0, at: 1.0))
        #expect(extra == .none)
    }

    @Test func positiveDeltaGoesPrevious() {
        var tracker = makeTracker()
        _ = tracker.handle(.began)
        let outputs = drag(&tracker, dx: 60, steps: 3)
        #expect(outputs[2] == .trigger(.previous))
    }

    @Test func verticalIntentIsRejected() {
        var tracker = makeTracker()
        _ = tracker.handle(.began)
        // Strongly vertical gesture: locks out before horizontals can engage.
        _ = tracker.handle(.changed(dx: 5, dy: 40, at: 0))
        let output = tracker.handle(.changed(dx: -100, dy: 30, at: 0.016))
        #expect(output == .none)
        let end = tracker.handle(.ended(at: 0.032))
        #expect(end == .none)
    }

    @Test func shortSlowDragSettles() {
        var tracker = makeTracker()
        _ = tracker.handle(.began)
        _ = drag(&tracker, dx: -10, steps: 5) // 50pt < 150pt, ~0 velocity at end
        let out = tracker.handle(.ended(at: 10))
        #expect(out == .settle)
    }

    @Test func fastFlickTriggersWithoutThreshold() {
        var tracker = makeTracker()
        _ = tracker.handle(.began)
        // 30pt total but very fast: 3 events of 15pt within ~0.02s → ~750pt/s
        var t = 0.0
        for _ in 0..<3 {
            _ = tracker.handle(.changed(dx: -15, dy: 0, at: t))
            t += 0.01
        }
        let out = tracker.handle(.ended(at: t))
        #expect(out == .trigger(.next))
    }

    @Test func edgeResistanceAndSettleAtBounds() {
        var tracker = makeTracker()
        tracker.canGoNext = false
        _ = tracker.handle(.began)
        let outputs = drag(&tracker, dx: -50, steps: 4) // pushing against last page
        // Offset is damped, never triggers.
        #expect(!outputs.contains { $0 == .trigger(.next) })
        if case .drag(let offset) = outputs[3] {
            #expect(abs(offset) < abs(-200.0))
        } else {
            Issue.record("expected damped drag output")
        }
        let out = tracker.handle(.ended(at: 1))
        #expect(out == .settle) // rubber-band: snap back, no turn
    }

    @Test func cancelledGestureSettlesIfTracking() {
        var tracker = makeTracker()
        _ = tracker.handle(.began)
        _ = drag(&tracker, dx: -20, steps: 2)
        let out = tracker.handle(.cancelled)
        #expect(out == .settle)
    }

    @Test func newGestureAfterTriggerWorks() {
        var tracker = makeTracker()
        _ = tracker.handle(.began)
        _ = drag(&tracker, dx: -40, steps: 4)
        _ = tracker.handle(.ended(at: 1))
        _ = tracker.handle(.began)
        let outputs = drag(&tracker, dx: -40, steps: 4, start: 2)
        #expect(outputs[3] == .trigger(.next))
    }

    @Test func wrapAroundAllowsTurnAtLastPage() {
        var tracker = makeTracker()
        tracker.canGoNext = true // wrap enabled: always allowed
        _ = tracker.handle(.began)
        let outputs = drag(&tracker, dx: -40, steps: 4)
        #expect(outputs[3] == .trigger(.next))
    }
}
