import Testing
@testable import FlickCore

struct ImageNavigatorTests {

    @Test func emptyNavigator() {
        var nav = ImageNavigator()
        #expect(nav.isEmpty)
        #expect(nav.index == -1)
        #expect(!nav.canGoNext)
        #expect(!nav.canGoPrevious)
        let movedNext = nav.goNext()
        let movedPrevious = nav.goPrevious()
        #expect(!movedNext)
        #expect(!movedPrevious)
    }

    @Test func stepThroughBoundaries() {
        var nav = ImageNavigator(count: 3, index: 0)
        #expect(!nav.canGoPrevious)
        #expect(nav.canGoNext)

        var moved = nav.goPrevious()          // already at first, stays put
        #expect(!moved)
        #expect(nav.index == 0)

        moved = nav.goNext()
        #expect(moved)
        #expect(nav.index == 1)
        moved = nav.goNext()
        #expect(moved)
        #expect(nav.index == 2)
        #expect(!nav.canGoNext)
        moved = nav.goNext()                  // last image, no wrap
        #expect(!moved)
        #expect(nav.index == 2)

        moved = nav.goPrevious()
        #expect(moved)
        #expect(nav.index == 1)
    }

    @Test func firstAndLast() {
        var nav = ImageNavigator(count: 10, index: 5)
        var moved = nav.goLast()
        #expect(moved)
        #expect(nav.index == 9)
        moved = nav.goFirst()
        #expect(moved)
        #expect(nav.index == 0)
        moved = nav.goFirst()                 // no-op when already there
        #expect(!moved)
    }

    @Test func wrapAround() {
        var nav = ImageNavigator(count: 3, index: 2, wrapsAround: true)
        #expect(nav.canGoNext)
        var moved = nav.goNext()
        #expect(moved)
        #expect(nav.index == 0)               // wrapped to first
        moved = nav.goPrevious()
        #expect(moved)
        #expect(nav.index == 2)               // wrapped back to last
    }

    @Test func goToValidation() {
        var nav = ImageNavigator(count: 5, index: 2)
        var moved = nav.goTo(2)               // same index: no change
        #expect(!moved)
        moved = nav.goTo(-1)                  // out of range
        #expect(!moved)
        moved = nav.goTo(5)                   // out of range
        #expect(!moved)
        moved = nav.goTo(4)
        #expect(moved)
        #expect(nav.index == 4)
    }

    @Test func resetClampsIndex() {
        var nav = ImageNavigator()
        nav.reset(count: 3, index: 99)
        #expect(nav.index == 2)
        nav.reset(count: 3, index: -5)
        #expect(nav.index == 0)
        nav.reset(count: 0)
        #expect(nav.index == -1)
    }

    @Test func updateAfterListShrinks() {
        var nav = ImageNavigator(count: 5, index: 4)
        nav.update(count: 2)                  // last files removed
        #expect(nav.count == 2)
        #expect(nav.index == 1)               // clamped to last valid
    }
}
