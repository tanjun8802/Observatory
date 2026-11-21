import Foundation

enum WCALiveFeed {
    private static let site = URL(string: "https://live.worldcubeassociation.org/")!
    private static let query = """
        query ObservatoryCompetitions($from: Date!) { competitions(from: $from) { id name startTime endTime venues { name country { name } } } }
        """
    private static let listingPrompt = """
        At each refresh, open the official WCA Live site at https://live.worldcubeassociation.org/ and show the competitions currently in progress. For each, display its name, location, and a direct link to its live results. If none are listed as in progress, say so. If the source is unavailable, report that live status could not be verified. Use read-only access.
        """

    // A title is editable and can be reused for rankings, individual competitors or other requests.
    static func matches(_ monitor: Monitor) -> Bool {
        guard monitor.kind == .codex, let prompt = monitor.prompt else { return false }
        return prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .caseInsensitiveCompare(listingPrompt) == .orderedSame
    }

    static func fetch(_ monitor: Monitor) async throws -> Reading {
        try await fetch(monitor, now: .now) { try await URLSession.shared.data(for: $0) }
    }

    static func fetch(_ monitor: Monitor, now: Date,
                      load: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Reading {
        guard matches(monitor) else { throw Failure("This request is outside the WCA Live competition listing.") }
        // Home.jsx requests competitions starting since the same local calendar date one month ago.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: calendar.startOfDay(for: now))!
        let from = monthAgo.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
        let variables = try JSONEncoder().encode(["from": from])
        var components = URLComponents(url: site.appending(path: "api"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "variables", value: String(decoding: variables, as: UTF8.self))]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await load(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url?.scheme == "https",
                  http.url?.host == site.host, http.url?.path == "/api" else {
                throw Failure("The official API did not answer.")
            }
            guard http.statusCode == 200 else { throw Failure("The official API returned HTTP \(http.statusCode).") }
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.errors?.isEmpty != false, let payload = envelope.data else {
                throw Failure("The official API returned incomplete results.")
            }
            return try reading(payload.competitions, now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as Failure {
            throw error
        } catch is DecodingError {
            throw Failure("The official API returned unreadable competition data.")
        } catch {
            throw Failure("The official API could not be reached.")
        }
    }

    private struct Failure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { "WCA Live status could not be verified. \(reason)" }
    }

    private struct Envelope: Decodable {
        struct Payload: Decodable { let competitions: [Competition] }
        struct QueryError: Decodable { let message: String }
        let data: Payload?
        let errors: [QueryError]?
    }

    private struct Competition: Decodable {
        struct Venue: Decodable {
            struct Country: Decodable { let name: String }
            let name: String
            let country: Country
        }
        let id, name, startTime, endTime: String
        let venues: [Venue]

        var location: String {
            var locations: [String] = []
            for venue in venues {
                let name = venue.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let country = venue.country.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let venueName = name.caseInsensitiveCompare("Venue") == .orderedSame ? "" : name
                let place = [venueName, country].filter { !$0.isEmpty }.joined(separator: ", ")
                if !place.isEmpty && !locations.contains(place) { locations.append(place) }
            }
            return locations.isEmpty ? "Location not listed by WCA Live" : locations.joined(separator: " / ")
        }
    }

    private static func reading(_ competitions: [Competition], now: Date) throws -> Reading {
        let seconds = Date.ISO8601FormatStyle()
        let subseconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        func timestamp(_ text: String) -> Date? {
            (try? seconds.parse(text)) ?? (try? subseconds.parse(text))
        }
        var active: [(start: Date, end: Date, text: String)] = []
        for competition in competitions {
            guard let start = timestamp(competition.startTime), let end = timestamp(competition.endTime),
                  start <= end else { throw Failure("A competition's activity times are invalid.") }
            // WCA's isInProgress uses differenceInMinutes (truncated) > 60 on either side.
            guard start.timeIntervalSince(now) < 61 * 60, now.timeIntervalSince(end) < 61 * 60 else { continue }
            let name = competition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let id = UInt64(competition.id), id > 0,
                  String(id) == competition.id else { throw Failure("A listed competition has an invalid name or results ID.") }
            let url = site.appending(path: "competitions").appending(path: competition.id)
            active.append((start, end, "\(name) — \(competition.location)\n\(url.absoluteString)"))
        }
        let entries = active.sorted { ($0.start, $0.end, $0.text) < ($1.start, $1.end, $1.text) }
        let value = entries.isEmpty ? "No competitions are listed as in progress on WCA Live."
            : entries.map(\.text).joined(separator: "\n\n")
        return Reading(value: value, detail: "WCA Live, right now", observedAt: now,
                       presentation: FeedPresentation(kind: .metrics, metrics: [FeedMetric(label: "Competitions in progress", value: Double(entries.count), unit: "")],
                                                      sourceName: "WCA Live", sourceURL: site))
    }
}
