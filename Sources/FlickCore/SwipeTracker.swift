import Foundation

/// Pure state machine that turns a stream of trackpad scroll-wheel events into
/// page-turn decisions. No AppKit: fully deterministic and unit-testable.
///
/// Conventions: negative accumulated X (fingers moving left) means "next",
/// positive means "previous" — mirroring natural scrolling.
public struct SwipeTracker {

    public enum Direction: Int, Equatable {
        case next
        case previous
    }

    public enum Event {
        case began
        /// Point deltas since the previous event + event timestamp.
        case changed(dx: Double, dy: Double, at: TimeInterval)
        case ended(at: TimeInterval)
        case cancelled
    }

    public enum State: Equatable {
        case idle
        /// Collecting deltas, direction not yet locked.
        case accumulating
        /// Locked to horizontal page-drag.
        case horizontal
        /// Triggered or rejected; ignores input until a new `began`.
        case finished
    }

    public enum Output: Equatable {
        case none
        /// Horizontal offset (points) the UI should apply while dragging —
        /// already damped when pushing against an unavailable edge.
        case drag(Double)
        case trigger(Direction)
        /// Gesture ended without turning — snap back to rest.
        case settle
    }

    // MARK: - Tunables

    /// Width used for the distance threshold; the view updates it per gesture.
    public var viewportWidth: Double = 800
    /// Fraction of `viewportWidth` that commits a turn mid-drag.
    public var thresholdFraction = 0.15
    /// Points of dominant-axis travel needed to lock the gesture direction.
    public var directionLockDistance = 8.0
    /// Release velocity (points/sec) that triggers a turn regardless of distance.
    public var velocityThreshold = 500.0
    /// Multiplier applied to the drag offset when pulling an unavailable edge.
    public var edgeResistance = 0.3

    /// Edge availability, mirrored from the navigator before each event.
    public var canGoNext = true
    public var canGoPrevious = true

    // MARK: - State

    public private(set) var state: State = .idle
    private var accX = 0.0
    private var accY = 0.0
    private var samples: [(t: TimeInterval, x: Double)] = []

    public init() {}

    public mutating func reset() {
        state = .idle
        accX = 0
        accY = 0
        samples = []
    }

    public mutating func handle(_ event: Event) -> Output {
        switch event {
        case .began:
            reset()
            state = .accumulating
            return .none

        case .changed(let dx, let dy, let t):
            switch state {
            case .finished:
                return .none
            case .idle:
                state = .accumulating
            case .accumulating, .horizontal:
                break
            }
            accX += dx
            accY += dy
            samples.append((t, accX))
            samples.removeAll { t - $0.t > 0.12 }

            if state == .accumulating {
                let ax = abs(accX), ay = abs(accY)
                if ax >= directionLockDistance || ay >= directionLockDistance {
                    if ax > ay * 1.2 {
                        state = .horizontal
                    } else if ay > ax * 1.3 {
                        // Mostly-vertical intent: let the scroller have it.
                        state = .finished
                        return .none
                    }
                }
            }
            guard state == .horizontal else { return .none }

            let direction: Direction = accX < 0 ? .next : .previous
            if isAllowed(direction), abs(accX) >= threshold {
                state = .finished
                return .trigger(direction)
            }
            return .drag(isAllowed(direction) ? accX : accX * edgeResistance)

        case .ended(let t):
            defer { reset() }
            guard state == .horizontal else { return .none }
            let direction: Direction = accX < 0 ? .next : .previous
            if isAllowed(direction) && abs(velocity(at: t)) >= velocityThreshold {
                return .trigger(direction)
            }
            return .settle

        case .cancelled:
            let wasTracking = state == .horizontal
            reset()
            return wasTracking ? .settle : .none
        }
    }

    private var threshold: Double {
        viewportWidth * thresholdFraction
    }

    private func isAllowed(_ direction: Direction) -> Bool {
        direction == .next ? canGoNext : canGoPrevious
    }

    /// Estimates release velocity from recent (timestamp, accumulatedX) samples.
    private func velocity(at end: TimeInterval) -> Double {
        let window = samples.filter { end - $0.t <= 0.12 }
        guard let first = window.first, let last = window.last,
              last.t - first.t > 0.005 else {
            return 0
        }
        return (last.x - first.x) / (last.t - first.t)
    }
}
