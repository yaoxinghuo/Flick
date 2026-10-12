import Foundation

/// Pure navigation state machine: which image is current, whether we can move,
/// and how boundaries behave (stop vs. wrap). No I/O, fully testable.
public struct ImageNavigator: Equatable {
    public private(set) var count: Int = 0
    /// Index of the current image, `-1` when the list is empty.
    public private(set) var index: Int = -1
    /// Whether next/previous wraps around at the ends.
    public var wrapsAround: Bool = false

    public init(count: Int = 0, index: Int = -1, wrapsAround: Bool = false) {
        reset(count: count, index: index)
        self.wrapsAround = wrapsAround
    }

    public var isEmpty: Bool { count == 0 }
    public var canGoPrevious: Bool { wrapsAround ? count > 1 : index > 0 }
    public var canGoNext: Bool { wrapsAround ? count > 1 : index < count - 1 }

    /// Replaces the list. `index` is clamped into `[0, count)`; `count == 0` gives `-1`.
    public mutating func reset(count: Int, index: Int = 0) {
        self.count = max(0, count)
        self.index = self.count == 0 ? -1 : min(max(0, index), self.count - 1)
    }

    /// The list changed underneath us (files added/removed). Keeps `index` valid:
    /// if the current file is gone the caller passes the index of the nearest
    /// surviving position.
    public mutating func update(count: Int) {
        reset(count: count, index: index < 0 ? 0 : index)
    }

    @discardableResult
    public mutating func goNext() -> Bool {
        goTo(index + 1, allowWrap: true)
    }

    @discardableResult
    public mutating func goPrevious() -> Bool {
        goTo(index - 1, allowWrap: true)
    }

    @discardableResult
    public mutating func goFirst() -> Bool {
        goTo(0)
    }

    @discardableResult
    public mutating func goLast() -> Bool {
        goTo(count - 1)
    }

    /// Moves to `index`. Returns `true` when the current index actually changed.
    @discardableResult
    public mutating func goTo(_ newIndex: Int, allowWrap: Bool = false) -> Bool {
        guard count > 0 else { return false }
        var target = newIndex
        if allowWrap && wrapsAround {
            if target >= count { target = 0 }
            if target < 0 { target = count - 1 }
        }
        guard target >= 0, target < count, target != index else { return false }
        index = target
        return true
    }
}
