import Foundation
import Testing
@testable import Observatory

@Suite struct CanvasLayoutTests {
    @Test @MainActor func compactBoardFitsThreeFeedsAcrossWhenOpeningAVersion12Board() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let feeds = (0..<3).map { Monitor(kind: .codex, title: "Feed \($0)") }
        let cells = zip(feeds, [(0, 0), (3, 0), (0, 7)]).reduce(into: [String: [String: Int]]()) { layout, pair in
            layout[pair.0.id.uuidString] = ["column": pair.1.0, "row": pair.1.1, "width": 3, "height": 7]
        }
        let snapshot: [String: Any] = [
            "monitors": try JSONSerialization.jsonObject(with: JSONEncoder().encode(feeds)),
            "readings": [], "lastChecked": [], "errors": [], "layout": cells
        ]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        let store = DashboardStore(file: file)
        let frames = try feeds.map { feed in
            CanvasLayout.frame(for: try #require(store.layout.placements[feed.id]), in: 900)
        }
        #expect(frames.allSatisfy { $0.minY == 0 && $0.height <= 300 })
        #expect(frames[0].maxX < frames[1].minX && frames[1].maxX < frames[2].minX)
    }

    @Test @MainActor func firstReadingUsesASquareCardAndManualResizingSurvivesRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "board.json")
        let monitor = Monitor(kind: .codex, title: "Daily notes")
        let summary = Reading(value: "All checks passed.", detail: "Codex", observedAt: .now)
        let store = DashboardStore(file: file) { _ in summary }
        store.add(monitor)
        func waitForReading() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !store.refreshing.isEmpty {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        try await waitForReading()
        let compact = try #require(store.layout.placements[monitor.id])
        #expect(compact.width == compact.height)
        let chosen = WidgetPlacement(column: 1, row: 2, width: 4, height: 9)
        store.placeWidget(monitor.id, at: chosen)
        store.refresh(monitor)
        try await waitForReading()
        #expect(DashboardStore(file: file).layout.placements[monitor.id] == chosen)
    }

    @Test func fourDefaultTilesFitAcrossAndStaySquareWhenTheWindowResizes() throws {
        let feeds = (0..<5).map { Monitor(kind: .json, title: "Feed \($0)") }
        let layout = CanvasLayout(monitors: feeds)
        for width: CGFloat in [679, 727, 909, 1560] {
            let frames = try feeds.map { feed in
                CanvasLayout.frame(for: try #require(layout.placements[feed.id]), in: width)
            }
            #expect(frames.prefix(4).allSatisfy { $0.minY == 0 && abs($0.width - $0.height) < 0.01 })
            #expect(abs(frames[3].maxX - width) < 0.01)
            #expect(frames[4].minX == 0 && frames[4].minY > frames[0].maxY)
        }
    }

    @Test @MainActor func version13CustomLayoutCanBeRepackedIntoPersistentSquares() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let feeds = (0..<4).map { Monitor(kind: .json, title: "Feed \($0)") }
        let encodedFeeds = try JSONSerialization.jsonObject(with: JSONEncoder().encode(feeds))
        var cells: [String: [String: Int]] = [:]
        for (index, feed) in feeds.enumerated() {
            cells[feed.id.uuidString] = ["column": (index % 3) * 2, "row": (index / 3) * 4, "width": 2, "height": 4]
        }
        func writeBoard() throws {
            let board: [String: Any] = ["monitors": encodedFeeds, "readings": [], "lastChecked": [], "errors": [],
                                        "layoutVersion": 2, "layout": cells]
            try JSONSerialization.data(withJSONObject: board).write(to: file)
        }
        try writeBoard()
        let squares = CanvasLayout(monitors: feeds)
        #expect(DashboardStore(file: file).layout == squares)
        cells[feeds[0].id.uuidString] = ["column": 2, "row": 12, "width": 4, "height": 5]
        try writeBoard()
        let custom = DashboardStore(file: file)
        let old = try #require(custom.layout.placements[feeds[0].id])
        let frame = CanvasLayout.frame(for: old, in: 900)
        #expect(abs(frame.minX - 908.0 / 3) < 0.01)
        #expect(abs(frame.maxX - 900) < 0.01)
        custom.arrangeAsSquares()
        #expect(DashboardStore(file: file).layout == squares)
    }

    @Test func dragAndResizeUseTheRenderedPitchAtEveryWidth() {
        let cell = WidgetPlacement(column: 0, row: 1, width: 6, height: 4)
        for width: CGFloat in [645, 699, 875, 1500] {
            let pitch = CanvasLayout.columnPitch(for: width)
            let translation = CGSize(width: pitch * 1.1, height: -pitch * 0.6)
            let moved = WidgetEdit.move.candidate(from: cell, translation: translation, canvasWidth: width)
            #expect(moved == WidgetPlacement(column: 1, row: 0, width: 6, height: 4))
            let resized = WidgetEdit.resize.candidate(from: cell, translation: translation, canvasWidth: width)
            #expect(resized == WidgetPlacement(column: 0, row: 1, width: 7, height: 3))
            let original = CanvasLayout.frame(for: cell, in: width)
            let frame = CanvasLayout.frame(for: resized, in: width)
            #expect(original.origin == frame.origin)
            #expect(abs(frame.width - original.width - pitch) < 0.01)
            #expect(abs(original.height - frame.height - pitch) < 0.01)
            let right = WidgetEdit.move.candidate(from: cell, columns: 100, rows: -100)
            #expect(abs(CanvasLayout.frame(for: right, in: width).maxX - width) < 0.01)
            #expect(right.row == 0)
            #expect(WidgetEdit.resize.candidate(from: right, columns: 100, rows: -100) ==
                    WidgetPlacement(column: 18, row: 0, width: 6, height: CanvasLayout.minimumHeight))
        }
    }

    @Test func occupiedPositionsIncludingFilteredWidgetsStayReserved() throws {
        let feeds = (0..<6).map { Monitor(kind: .json, title: "Feed \($0)") }
        let ids = feeds.map(\.id)
        var layout = CanvasLayout(monitors: feeds)
        let original = layout
        let first = try #require(layout.placements[ids[0]])
        let hidden = try #require(layout.placements[ids[1]])
        let didMove = layout.set(hidden, for: ids[0])
        #expect(!didMove)
        let didResize = layout.set(WidgetEdit.resize.candidate(from: first, columns: 1, rows: 0), for: ids[0])
        #expect(!didResize)
        #expect(layout == original)
        let free = try #require(layout.nextMove(for: ids[0], columns: 0, rows: 1))
        #expect(free.row == 12)
        let reachedFreeRow = layout.set(free, for: ids[0])
        #expect(reachedFreeRow)
        for id in ids.dropFirst() { #expect(layout.placements[id] == original.placements[id]) }
        #expect(layout.nextMove(for: ids[0], columns: 0, rows: -1) == first)
        for width: CGFloat in [645, 875] {
            let frames = ids.compactMap { layout.placements[$0].map { CanvasLayout.frame(for: $0, in: width) } }
            for (index, frame) in frames.enumerated() {
                #expect(frame.minX >= 0 && frame.maxX <= width + 0.001)
                #expect(frames.dropFirst(index + 1).allSatisfy { !$0.intersects(frame) })
            }
        }
    }

    @Test func repairsOnlyInvalidMetadataAndAllocatesAroundSurvivingWidgets() throws {
        let new = UUID(), saved = UUID(), overlapping = UUID(), invalid = UUID(), orphan = UUID(), broken = UUID()
        let position = ["column": 0, "row": 0, "width": 4, "height": 3]
        let json: [String: Any] = [saved.uuidString: position, overlapping.uuidString: position,
                                   orphan.uuidString: position, invalid.uuidString: ["column": Int.max, "row": Int.max,
                                                                                  "width": Int.max, "height": -1],
                                   broken.uuidString: ["width": "bad"]]
        let raw = try JSONDecoder().decode(CanvasLayout.self, from: JSONSerialization.data(withJSONObject: json))
        let ids = [new, saved, overlapping, invalid, broken]
        let feeds = ids.map { Monitor(id: $0, kind: .json, title: "Feed") }
        let restored = CanvasLayout(monitors: feeds, saved: raw)
        #expect(Set(restored.placements.keys) == Set(ids))
        #expect(restored.placements[saved] == WidgetPlacement(column: 0, row: 0, width: 4, height: 3))
        for (id, cell) in restored.placements { #expect(restored.fits(cell, for: id)) }
        #expect(CanvasLayout(monitors: feeds, saved: restored) == restored)
    }

    @Test @MainActor func legacyBoardRetainsGeometryThroughRefreshDeletionAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "board.json")
        let feeds = MonitorKind.allCases.map { Monitor(kind: $0, title: $0.rawValue) }
        let reading = Reading(value: "Loaded", detail: "Temporary fixture", observedAt: .now)
        let snapshot: [String: Any] = [
            "monitors": try JSONSerialization.jsonObject(with: JSONEncoder().encode(feeds)),
            "readings": [], "lastChecked": [], "errors": []
        ]
        let legacy = try JSONSerialization.data(withJSONObject: snapshot)
        try legacy.write(to: file)
        let store = DashboardStore(file: file) { _ in reading }
        #expect(try Data(contentsOf: file) == legacy)
        #expect(store.layout.placements.count == feeds.count)

        let moved = WidgetPlacement(column: 1, row: 10, width: 4, height: 3)
        store.placeWidget(feeds[0].id, at: moved)
        let arranged = store.layout
        store.refresh(feeds[0])
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !store.refreshing.isEmpty {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.readings[feeds[0].id] == reading)
        #expect(store.layout == arranged)
        let reopened = DashboardStore(file: file) { _ in reading }
        #expect(reopened.layout == arranged)
        let deleted = feeds[1]
        reopened.remove(deleted)
        reopened.placeWidget(deleted.id, at: moved)
        let scheduled = Monitor(kind: .codex, title: "Scheduled", schedule: .daily(hour: 9, minute: 0))
        reopened.add(scheduled)
        let tracked = Monitor(kind: .codex, title: "Tracked")
        reopened.add(tracked, initialReading: reading)
        let final = DashboardStore(file: file) { _ in reading }
        #expect(final.layout == reopened.layout)
        #expect(final.layout.placements[deleted.id] == nil)
        #expect(final.layout.placements[scheduled.id] != nil && final.layout.placements[tracked.id] != nil)
        for feed in feeds where feed.id != deleted.id {
            #expect(final.layout.placements[feed.id] == arranged.placements[feed.id])
        }
        #expect(final.readings[tracked.id] == reading)
    }
}
