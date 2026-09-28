import Foundation
import Testing
@testable import AteKit

@MainActor
@Suite("Sheets rise once their rows are in hand")
struct SheetReadinessTests {
    @Test func aReadThatAnswersInTimeIsWaitedFor() async {
        var landed = false
        let ready = await SheetReadiness.wait(atMost: .seconds(5)) {
            try? await Task.sleep(for: .milliseconds(20))
            landed = true
        }
        #expect(ready)
        #expect(landed)
    }

    @Test func aSlowReadIsNotWaitedForButIsNotCutShort() async throws {
        let box = Box()
        let ready = await SheetReadiness.wait(atMost: .milliseconds(30)) {
            try? await Task.sleep(for: .milliseconds(250))
            box.landed = true
        }
        #expect(ready == false)
        #expect(box.landed == false)
        try await Task.sleep(for: .milliseconds(600))
        #expect(box.landed, "the read keeps going and lands in the sheet that is already up")
    }

    @MainActor
    private final class Box {
        var landed = false
    }

    @Test func aSheetThatWentUpEarlyHoldsItsReservedHeight() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.head = 50
        fit.body = 40 // still rows
        fit.reserve(800)
        #expect(fit.tallest == 800)
        fit.body = 300 // the rows land, shorter than the reserve
        #expect(fit.tallest == 800, "it does not move")
    }
}

/// The bottom sheet that fits what it holds.
@Suite("The fitted sheet")
struct SheetFitTests {
    @Test func aSheetWithAPillFitsHeadContentAndPill() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.hasFoot = true
        fit.head = 90
        fit.body = 240
        #expect(fit.tallest == 0, "not until the pill is measured too")
        fit.foot = 88
        #expect(fit.tallest == CGFloat(90 + 240 + 88 + 28))
    }

    @Test func aSheetWithoutAPillKeepsTheDesignsClearance() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.head = 50
        fit.body = 240
        #expect(fit.tallest == CGFloat(50 + 240 + 34 + 14))
    }

    @Test func itGrowsWithItsContentAndNeverShrinksUnderTheThumb() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.head = 50
        fit.body = 100
        fit.body = 400
        let grown = fit.tallest
        fit.body = 60 // results thinning out as you type
        #expect(fit.tallest == grown)
    }

    @Test func nothingIsFittedBeforeTheFirstLayout() {
        var fit = AteSheetFit(gap: 14, bottom: 34)
        fit.body = 300
        #expect(fit.tallest == 0)
    }
}
