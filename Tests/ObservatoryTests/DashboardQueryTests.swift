import Foundation
import Testing
@testable import Observatory

struct DashboardQueryTests {
    @Test @MainActor func creatingDailyFeedGetsAnImmediateReadingAndKeepsItsSchedule() async throws {
        let reply = CodexClient.Result(text: #"""
        {"result":{"title":"London weather","prompt":"Weather in London in °C","cadence":"daily",
         "hour":8,"minute":0,"minutes":0,"runAt":""}}
        """#, searchedWeb: false)
        guard case .feed(let proposal) = try DashboardQuery.interpret(reply, question: "Set up a daily weather feed") else {
            Issue.record("Expected a feed draft")
            return
        }
        let monitor = try proposal.monitor()
        #expect(monitor.schedule == .daily(hour: 8, minute: 0))
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reading = Reading(value: "Cloudy", detail: "Fixture", observedAt: .now)
        var requests: [UUID] = []
        let store = DashboardStore(file: dir.appending(path: "board.json")) { feed in
            requests.append(feed.id)
            return reading
        }
        store.add(monitor)
        let later = Monitor(kind: .codex, title: "Later", schedule: .once(.now.addingTimeInterval(86400)))
        store.add(later)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !store.refreshing.isEmpty {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests == [monitor.id])
        #expect(store.readings[monitor.id] == reading)
        #expect(store.readings[later.id] == nil)
        #expect(store.nextRefresh(for: monitor) == monitor.schedule?.next(after: store.lastChecked[monitor.id] ?? .now))
    }

    @Test func ordinaryQuestionRoutesToANumericAnswer() throws {
        let reply = CodexClient.Result(text: #"""
        {"result":{"status":"complete","kind":"metrics","liveFacts":false,"answer":"42 seats",
          "metrics":[{"label":"Capacity","value":42,"unit":"seats"}],"evidence":"6 rows × 7 seats"}}
        """#, searchedWeb: false)
        guard case .answer(let reading) = try DashboardQuery.interpret(reply, question: "6 rows of 7 seats?") else {
            Issue.record("Expected an answer")
            return
        }
        #expect(reading.presentation?.metrics == [FeedMetric(label: "Capacity", value: 42, unit: "seats")])
    }
}
