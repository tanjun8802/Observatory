import Foundation
import Testing
@testable import Observatory

struct FeedListTests {
    @Test func listRoundTripPreservesRowsIntroductionAndOrder() throws {
        let rows = [FeedRow(title: "Final", detail: "Open", value: "10:45", url: "https://example.com/final"),
                    FeedRow(title: "Final", detail: "Masters", value: "11:00")]
        let reading = Reading(value: "Two finals were reported.", detail: "Results", observedAt: .now,
                              presentation: .init(kind: .list, rows: rows, isPartial: true))
        let restored = try JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(reading))
        #expect(restored == reading)
        #expect(restored.presentation?.isPartial == true)
        #expect(restored.compactTileValue == "2 items")
        #expect(rows.first?.link?.host() == "example.com")
    }

    @Test func emptyListsAndReadingsSavedBeforeListsRemainDistinct() throws {
        let legacy = Data(#"{"kind":"metrics","metrics":[{"label":"Visitors","value":9,"unit":""}]}"#.utf8)
        let presentation = try JSONDecoder().decode(FeedPresentation.self, from: legacy)
        #expect(presentation.rows == nil && presentation.isPartial == nil && presentation.metrics.first?.value == 9)
        let empty = FeedPresentation(kind: .list, rows: [])
        #expect(try JSONDecoder().decode(FeedPresentation.self, from: JSONEncoder().encode(empty)).rows == [])
    }

    @Test func unavailableOrNonWebRowLinksRenderAsPlainText() {
        for url in ["file:///tmp/report", "https://name:secret@example.com/private", "https://", "report.html"] {
            #expect(FeedRow(title: "Report", detail: "", value: "", url: url).link == nil)
        }
    }
}
