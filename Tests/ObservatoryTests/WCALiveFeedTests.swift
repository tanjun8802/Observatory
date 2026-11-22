import Foundation
import Testing
@testable import Observatory

@Suite struct WCALiveFeedTests {
    private let savedPrompt = """
        At each refresh, open the official WCA Live site at https://live.worldcubeassociation.org/ and show the competitions currently in progress. For each, display its name, location, and a direct link to its live results. If none are listed as in progress, say so. If the source is unavailable, report that live status could not be verified. Use read-only access.
        """
    private let recordsPrompt = " Show me the latest records, the event, time, name, and the competition locations."
    private let scrollPrompt = " contain it inside the feed if the list is too long, I can scroll it manually"
    private let now = Date(timeIntervalSince1970: 1_798_603_200) // 2026-12-30 04:00 UTC

    private var monitor: Monitor { Monitor(kind: .codex, title: "WCA Live Results", prompt: savedPrompt) }

    @Test func matchesSavedRequestButLeavesEditsAndOtherMonitorKindsAlone() {
        var feed = monitor
        #expect(WCALiveFeed.matches(feed))
        feed.title = "Cube watch"
        feed.prompt = savedPrompt.uppercased().replacingOccurrences(of: " ", with: "\n ")
        #expect(WCALiveFeed.matches(feed))
        feed.prompt = savedPrompt + recordsPrompt + scrollPrompt
        #expect(WCALiveFeed.matches(feed))
        feed.prompt = savedPrompt + recordsPrompt
        #expect(WCALiveFeed.matches(feed))
        for request in [
            savedPrompt + " Also include recent records with event, result, competitor and venue. Make the list scrollable.",
            "List current WCA Live competitions and recent records with events, scores and names.",
            "Show ongoing competitions on the official WCA Live site with names, locations and live results links.",
            "Show WCA Live competitions currently in progress and the latest records. Keep the list scrollable inside the card."
        ] {
            feed.prompt = request
            #expect(WCALiveFeed.matches(feed), "Unmatched request: \(request)")
        }
        for request in ["List current WCA Live competitions and recent records only in the UK.",
                        "List current WCA Live competitions and recent records for a particular competitor.",
                        "List WCA Live upcoming competitions.", "List ongoing competitions elsewhere.",
                        "Show WCA Live rankings for 3x3 single."] {
            feed.prompt = request
            #expect(!WCALiveFeed.matches(feed))
        }
        feed.prompt = savedPrompt + recordsPrompt + " Show world records only."
        #expect(!WCALiveFeed.matches(feed))
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
        let entries = try #require(reading.presentation?.rows)
        #expect(entries.map(\.title) == ["Recently ended", "Starting soon"])
        #expect(entries.first?.detail == "Hall A, Finland / Hall B, Sweden")
        #expect(entries.compactMap(\.url) == ["https://live.worldcubeassociation.org/competitions/15",
                                             "https://live.worldcubeassociation.org/competitions/12"])
        #expect(reading.value.contains("2 competitions in progress"))
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
    private func record(event: String, type: String, score: Int, entered: String) -> [String: Any] {
        let eventDetails = ["id": event, "name": "Event " + event]
        let competition: [String: Any] = [
            "id": "33", "name": "Winter Open", "venues": [["name": "Hall", "country": ["name": "Finland"]]]
        ]
        let round: [String: Any] = ["id": "57", "competitionEvent": ["event": eventDetails, "competition": competition]]
        return ["tag": "NR", "type": type, "attemptResult": score,
                "result": ["person": ["name": "Jane"], "round": round, "enteredAt": entered]]
    }

    private func combined(competitions: Data?, records: Data?) async throws -> Reading {
        let monitor = Monitor(kind: .codex, title: "Cube watch", prompt: savedPrompt + recordsPrompt + scrollPrompt)
        return try await WCALiveFeed.fetch(monitor, now: now) { request in
            let url = try #require(request.url)
            let isRecords = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "query" }?.value?.contains("recentRecords") == true
            guard let body = isRecords ? records : competitions else { throw URLError(.timedOut) }
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func combinedFeedDisplaysChronologicalScoresNamesLocationsAndRoundLinks() async throws {
        let first = "2026-12-29T11:45:00Z", second = "2026-12-29T12:00:00Z"
        let records = [record(event: "333", type: "single", score: 6111, entered: first),
                       record(event: "333fm", type: "average", score: 2533, entered: second),
                       record(event: "333fm", type: "single", score: 16, entered: first),
                       record(event: "333mbf", type: "single", score: 900348002, entered: first)]
        let data = try JSONSerialization.data(withJSONObject: ["data": ["recentRecords": records]])
        let reading = try await combined(competitions: self.data([competition("5", "Active", start: -5000, end: 1000)]),
                                         records: data)
        let rows = try #require(reading.presentation?.rows)
        #expect(reading.presentation?.kind == .list && reading.presentation?.isPartial == false)
        #expect(rows.map(\.value) == ["In progress", "25.33 moves", "1:01.11", "16 moves", "11/13 · 58:00"])
        #expect(rows[1].title == "Event 333fm · NR average")
        #expect(rows[1].detail.hasPrefix("Jane · Winter Open · Hall, Finland · Entered "))
        #expect(rows[1].url == "https://live.worldcubeassociation.org/competitions/33/rounds/57")
        #expect(reading.value.contains("4 recent live records") && reading.value.contains("1 competition in progress"))
    }

    @Test func combinedSectionsReportUnavailableAndVerifiedEmptyIndependently() async throws {
        let emptyRecords = Data(#"{"data":{"recentRecords":[]}}"#.utf8)
        let emptyCompetitions = try data([])
        let valid = try await combined(competitions: emptyCompetitions, records: emptyRecords)
        #expect(valid.presentation?.isPartial == false && valid.value.contains("lists no recent records"))
        let liveOnly = try await combined(competitions: emptyCompetitions, records: nil)
        #expect(liveOnly.presentation?.isPartial == true)
        #expect(liveOnly.value.contains("No competitions") && liveOnly.value.contains("Recent records could not be verified"))
        let recordsOnly = try await combined(competitions: nil, records: emptyRecords)
        #expect(recordsOnly.presentation?.isPartial == true)
        #expect(recordsOnly.value.contains("Competitions in progress could not be verified"))
        #expect(recordsOnly.value.contains("lists no recent records"))
        await #expect(throws: (any Error).self) { try await combined(competitions: nil, records: nil) }
    }
}
