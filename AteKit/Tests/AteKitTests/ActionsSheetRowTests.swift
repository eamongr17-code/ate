import Testing
@testable import AteKit

@Suite("The one actions sheet")
struct ActionsSheetRowTests {
    @Test("Save, Share, Report, Block — in that order, everywhere")
    func order() {
        #expect(ActionsSheetRow.rows(canSave: true) == [.save, .share, .report, .block])
    }

    @Test("with nothing to save the Save row is absent, never disabled")
    func noSave() {
        #expect(ActionsSheetRow.rows(canSave: false) == [.share, .report, .block])
    }

    @Test("Report and Block ask first; only Block is destructive; only Share is not a write")
    func asks() {
        #expect(ActionsSheetRow.allCases.filter(\.confirms) == [.report, .block])
        #expect(ActionsSheetRow.allCases.filter(\.isDestructive) == [.block])
        #expect(ActionsSheetRow.allCases.filter { $0.isWrite == false } == [.share])
    }
}
