import Foundation
import Testing
@testable import Observatory

@Suite struct WCALiveFeedTests {
    private let savedPrompt = """
        At each refresh, open the official WCA Live site at https://live.worldcubeassociation.org/ and show the competitions currently in progress. For each, display its name, location, and a direct link to its live results. If none are listed as in progress, say so. If the source is unavailable, report that live status could not be verified. Use read-only access.
        """
    private let now = Date(timeIntervalSince1970: 1_798_603_200) // 2026-12-30 04:00 UTC

    private var monitor: Monitor { Monitor(kind: .codex, title: "WCA Live Results", prompt: savedPrompt) }

    @Test func matchesSavedRequestButLeavesEditsAndOtherMonitorKindsAlone() {
        var feed = monitor
        #expect(WCALiveFeed.matches(feed))
        feed.title = "Cube watch"
        feed.prompt = savedPrompt.uppercased().replacingOccurrences(of: " ", with: "\n ")
        #expect(WCALiveFeed.matches(feed))
        feed.title = "WCA Live Results"
        for other in [savedPrompt + " Show only competitions in Finland.", "Show WCA world records.", ""] {
            feed.prompt = other
            #expect(!WCALiveFeed.matches(feed))
        }
        feed.prompt = savedPrompt
        feed.kind = .json
        #expect(!WCALiveFeed.matches(feed))
    }

    private func competition(_ id: String, _ name: String, start: Int, end: Int) -> [String: Any] {
        let venues = [["name": "Hall A", "country": ["name": "Finland"]],
                      ["name": "Hall B", "country": ["name": "Sweden"]]]
        return ["id": id, "name": name, "startTime": now.addingTimeInterval(Double(start)).ISO8601Format(),
                "endTime": now.addingTimeInterval(Double(end)).ISO8601Format(), "venues": venues]
    }

    private func fetch(_ data: Data, status: Int = 200) async throws -> Reading {
        try await WCALiveFeed.fetch(monitor, now: now) { request in
            #expect(request.httpMethod == "GET")
            let url = try #require(request.url)
            #expect(url.scheme == "https" && url.host == "live.worldcubeassociation.org" && url.path == "/api")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.contains { $0.name == "query" && $0.value?.hasPrefix("query ") == true })
            #expect(items.contains { $0.name == "variables" && $0.value?.contains("from") == true })
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func data(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": ["competitions": rows]])
    }

    @Test func rightNowUsesOfficialMinuteBoundariesAndNumericResultsRoutes() async throws {
        let rows = [competition("12", "Starting soon", start: 3659, end: 6000),
                    competition("13", "Too early", start: 3660, end: 8000),
                    competition("14", "Too late", start: -9000, end: -3660),
                    competition("15", "Recently ended", start: -8000, end: -3659)]
        let reading = try await fetch(data(rows))
        #expect(reading.value.contains("Starting soon") && reading.value.contains("Recently ended"))
        #expect(!reading.value.contains("Too early") && !reading.value.contains("Too late"))
        #expect(reading.value.contains("Hall A, Finland") && reading.value.contains("Hall B, Sweden"))
        #expect(reading.value.contains("https://live.worldcubeassociation.org/competitions/12"))
        #expect(reading.value.contains("https://live.worldcubeassociation.org/competitions/15"))
        #expect(reading.observedAt == now && reading.presentation?.sourceName == "WCA Live")
    }

    @Test func verifiesAnEmptyListOrNoActiveTimes() async throws {
        for rows in [[], [competition("1", "Tomorrow", start: 90000, end: 93000)]] {
            let reading = try await fetch(data(rows))
            #expect(reading.value.contains("No competitions"))
        }
    }

    @Test func incompleteOrFailedResponsesCannotProduceAnEmptyReading() async throws {
        var badTime = competition("1", "Uncertain", start: 0, end: 10)
        badTime["endTime"] = "not a timestamp"
        for bad in [Data("<html>Enable JavaScript</html>".utf8),
                    Data(#"{"data":{"competitions":[]},"errors":[{"message":"upstream failure"}]}"#.utf8),
                    Data(#"{"data":{"competitions":null}}"#.utf8), Data(#"{"data":{}}"#.utf8),
                    try data([badTime]), try data([competition("../other", "Bad ID", start: 0, end: 1)]),
                    try data([competition("1", "Reversed dates", start: 100, end: 10)])] {
            await #expect(throws: (any Error).self) { try await fetch(bad) }
        }
        await #expect(throws: (any Error).self) { try await fetch(data([]), status: 503) }
        await #expect(throws: (any Error).self) {
            try await WCALiveFeed.fetch(monitor, now: now) { _ in throw URLError(.timedOut) }
        }
    }
}
