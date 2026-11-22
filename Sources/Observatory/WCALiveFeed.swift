import Foundation

enum WCALiveFeed {
    private static let site = URL(string: "https://live.worldcubeassociation.org/")!
    private static let competitionQuery = """
        query ObservatoryCompetitions($from: Date!) { competitions(from: $from) { id name startTime endTime venues { name country { name } } } }
        """
    private static let recordQuery = """
        query ObservatoryRecentRecords { recentRecords { tag type attemptResult result { enteredAt person { name } round { id competitionEvent { event { id name } competition { id name venues { name country { name } } } } } } } }
        """
    private static let listingPrompt = """
        At each refresh, open the official WCA Live site at https://live.worldcubeassociation.org/ and show the competitions currently in progress. For each, display its name, location, and a direct link to its live results. If none are listed as in progress, say so. If the source is unavailable, report that live status could not be verified. Use read-only access.
        """
    private enum Intent { case competitions, competitionsAndRecords }

    // Accept a bounded grammar of list requests. A country, competitor filter, negation,
    // ranking or unfamiliar action leaves the whole prompt for the general Codex provider.
    private static func intent(_ monitor: Monitor) -> Intent? {
        guard monitor.kind == .codex, let prompt = monitor.prompt else { return nil }
        func normalize(_ input: String) -> String {
            input.lowercased().replacingOccurrences(of: site.absoluteString, with: "wca live")
                .split { $0.isWhitespace || ".,!?:;()".contains($0) }.joined(separator: " ")
        }
        var rest = normalize(prompt)
        func consume(_ pattern: String) -> Bool {
            guard let match = rest.range(of: "^(?:" + pattern + ")(?: +|$)", options: .regularExpression) else { return false }
            rest.removeSubrange(rest.startIndex..<match.upperBound)
            return true
        }

        let source = #"(?:the )?(?:official )?wca live(?: site| website)?"#
        let active = #"(?:currently in progress|in progress|currently running|ongoing|current|active|live)"#
        let action = #"(?:(?:show|list|display|track|follow|include)(?: me)? )?(?:the )?"#
        let base = normalize(listingPrompt)
        if rest == base || rest.hasPrefix(base + " ") {
            rest = rest.dropFirst(base.count).trimmingCharacters(in: .whitespaces)
        } else {
            let request = rest
            let competitions = "(?:\(active) (?:\(source) )?competitions|(?:\(source) )?competitions (?:that are )?\(active)|\(source) \(active) competitions)"
            guard consume(action + competitions + "(?: (?:on|from|at) " + source + ")?") else { return nil }
            // The named source must belong to the competition request.
            guard request.dropLast(rest.count).contains("wca live") else { return nil }
            _ = consume(#"(?:with|including) (?:their )?(?:names?|locations?|venues?|(?:direct )?(?:live )?results links?)(?:(?: and)? (?:their )?(?:names?|locations?|venues?|(?:direct )?(?:live )?results links?))*"#)
        }

        let join = #"(?:(?:and|also|then) )*"#
        let records = join + #"(?:(?:show|include|list|display|add)(?: me)? )?(?:the )?(?:latest|recent|most recent) (?:live )?records"#
        let hasRecords = consume(records)
        if hasRecords {
            let item = #"(?:events?|(?:solve |result )?times?|results?|scores?|(?:competitor |holder )?names?|competitors?|record holders?|competition locations?|competition venues?|locations?|venues?|dates?)"#
            let fields = #"(?:(?:with|including|for each|showing) )?(?:the )?"# + item + #"(?:(?: and)? (?:the )?"# + item + ")*"
            _ = consume(fields)
        }

        let scroll = join + #"(?:(?:make|keep) (?:it|(?:the |this )?list) scrollable(?: (?:in|inside|within) (?:the |this )?(?:feed|card))?|(?:contain|keep) (?:it|the list) (?:inside|within|in) (?:the |this )?(?:feed|card)(?: if the list is too long)?(?: (?:so )?i can scroll (?:it )?(?:manually)?)?)"#
        _ = consume(scroll)
        guard rest.isEmpty else { return nil }
        return hasRecords ? .competitionsAndRecords : .competitions
    }

    static func matches(_ monitor: Monitor) -> Bool { intent(monitor) != nil }

    static func fetch(_ monitor: Monitor) async throws -> Reading {
        try await fetch(monitor, now: .now) { try await URLSession.shared.data(for: $0) }
    }

    static func fetch(_ monitor: Monitor, now: Date,
                      load: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Reading {
        guard let intent = intent(monitor) else { throw Failure("This request is outside the WCA Live feed.") }
        // WCA Live requests competitions starting since the same local calendar date one month ago.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: calendar.startOfDay(for: now))!
        let from = monthAgo.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
        let variables = try JSONEncoder().encode(["from": from])
        async let competitionResult = section {
            let payload: CompetitionList = try await query(competitionQuery, variables: variables, load: load)
            return try competitionRows(payload.competitions, now: now)
        }
        var records: Result<[FeedRow], Failure>?
        if intent == .competitionsAndRecords {
            records = try await section {
                let payload: RecordList = try await query(recordQuery, load: load)
                return try recordRows(payload.recentRecords)
            }
        }
        let competitions = try await competitionResult
        try Task.checkCancellation()
        var rows: [FeedRow] = []
        var summary: [String] = []
        var verifiedSections = 0
        switch competitions {
        case .success(let entries):
            verifiedSections += 1
            rows += entries
            summary.append(entries.isEmpty ? "No competitions are listed as in progress on WCA Live." :
                "\(entries.count) competition\(entries.count == 1 ? "" : "s") in progress.")
        case .failure(let error):
            summary.append("Competitions in progress could not be verified. \(error.reason)")
        }
        if let records {
            switch records {
            case .success(let entries):
                verifiedSections += 1
                rows += entries
                summary.append(entries.isEmpty ? "WCA Live lists no recent records." :
                    "\(entries.count) recent live record\(entries.count == 1 ? "" : "s") (provisional).")
            case .failure(let error):
                summary.append("Recent records could not be verified. \(error.reason)")
            }
        }
        let value = summary.joined(separator: " ")
        guard verifiedSections > 0 else { throw Failure(value) }
        let partial = records != nil && verifiedSections == 1
        return Reading(value: value, detail: "WCA Live", observedAt: now,
                       presentation: FeedPresentation(kind: .list, rows: rows, isPartial: partial,
                                                      sourceName: "WCA Live", sourceURL: site))
    }

    private struct Failure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }

    private static func section(_ operation: () async throws -> [FeedRow]) async throws -> Result<[FeedRow], Failure> {
        do {
            try Task.checkCancellation()
            return .success(try await operation())
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as Failure { return .failure(error) }
        catch is DecodingError { return .failure(Failure("The official API returned unreadable data.")) }
        catch { return .failure(Failure("The official API could not be reached.")) }
    }

    private struct Envelope<T: Decodable>: Decodable {
        let data: T?
        let errors: [QueryError]?
    }
    private struct QueryError: Decodable { let message: String }
    private struct CompetitionList: Decodable { let competitions: [Competition] }
    private struct RecordList: Decodable { let recentRecords: [Record] }

    private static func query<T: Decodable>(_ query: String, variables: Data? = nil,
                                            load: (URLRequest) async throws -> (Data, URLResponse)) async throws -> T {
        var components = URLComponents(url: site.appending(path: "api"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "query", value: query)]
        if let variables { items.append(URLQueryItem(name: "variables", value: String(decoding: variables, as: UTF8.self))) }
        components.queryItems = items
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await load(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https",
              http.url?.host == site.host, http.url?.path == "/api" else { throw Failure("The official API did not answer.") }
        guard http.statusCode == 200 else { throw Failure("The official API returned HTTP \(http.statusCode).") }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: bytes)
        guard envelope.errors?.isEmpty != false, let payload = envelope.data else {
            throw Failure("The official API returned incomplete results.")
        }
        return payload
    }

    private struct Competition: Decodable {
        struct Venue: Decodable {
            struct Country: Decodable { let name: String }
            let name: String
            let country: Country
        }
        let id, name: String
        let startTime, endTime: String?
        let venues: [Venue]

        var location: String {
            var locations: [String] = []
            for venue in venues {
                let name = venue.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let country = venue.country.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let venueName = ["venue", "all venues"].contains(name.lowercased()) ? "" : name
                let place = [venueName, country].filter { !$0.isEmpty }.joined(separator: ", ")
                if !place.isEmpty && !locations.contains(place) { locations.append(place) }
            }
            return locations.isEmpty ? "Location not listed by WCA Live" : locations.joined(separator: " / ")
        }

        func resultsURL() throws -> URL {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, validID(id) else {
                throw Failure("A competition has an invalid name or results ID.")
            }
            return site.appending(path: "competitions").appending(path: id)
        }
    }

    private static func validID(_ value: String) -> Bool {
        guard let number = UInt64(value) else { return false }
        return number > 0 && String(number) == value
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle().parse(value)) ??
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
    }

    private static func competitionRows(_ competitions: [Competition], now: Date) throws -> [FeedRow] {
        var active: [(start: Date, end: Date, row: FeedRow)] = []
        for competition in competitions {
            guard let start = timestamp(competition.startTime), let end = timestamp(competition.endTime),
                  start <= end else { throw Failure("A competition's activity times are invalid.") }
            // WCA's isInProgress uses differenceInMinutes (truncated) > 60 on either side.
            guard start.timeIntervalSince(now) < 61 * 60, now.timeIntervalSince(end) < 61 * 60 else { continue }
            let url = try competition.resultsURL()
            active.append((start, end, FeedRow(title: competition.name, detail: competition.location,
                                               value: "In progress", url: url.absoluteString)))
        }
        return active.sorted { ($0.start, $0.end, $0.row.title) < ($1.start, $1.end, $1.row.title) }.map(\.row)
    }

    private struct Record: Decodable {
        struct Result: Decodable {
            struct Person: Decodable { let name: String? }
            struct Round: Decodable {
                struct CompetitionEvent: Decodable {
                    struct Event: Decodable { let id, name: String }
                    let event: Event
                    let competition: Competition
                }
                let id: String
                let competitionEvent: CompetitionEvent
            }
            let person: Person
            let round: Round
            let enteredAt: String?
        }
        let tag, type: String
        let attemptResult: Int
        let result: Result
    }

    private static func recordRows(_ records: [Record]) throws -> [FeedRow] {
        let entries = try records.map { record in
            let round = record.result.round
            let event = round.competitionEvent.event
            let competition = round.competitionEvent.competition
            guard validID(round.id), !event.name.isEmpty, !event.id.isEmpty, !record.type.isEmpty,
                  !record.tag.isEmpty, record.attemptResult > 0 else { throw Failure("A record has invalid result data.") }
            let url = try competition.resultsURL().appending(path: "rounds").appending(path: round.id)
            let name = record.result.person.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let enteredAt = timestamp(record.result.enteredAt)
            var details = [name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed competitor", competition.name, competition.location]
            if let enteredAt { details.append("Entered " + enteredAt.formatted(date: .abbreviated, time: .omitted)) }
            let detail = details.joined(separator: " · ")
            let row = FeedRow(title: "\(event.name) · \(record.tag) \(record.type)", detail: detail,
                              value: score(record.attemptResult, event: event.id, type: record.type), url: url.absoluteString)
            return (date: enteredAt ?? .distantPast, row: row)
        }
        return entries.sorted { $0.date > $1.date }.map(\.row)
    }

    private static func score(_ value: Int, event: String, type: String) -> String {
        if event == "333fm" {
            return type == "single" ? "\(value) moves" : String(format: "%.2f moves", Double(value) / 100)
        }
        if event == "333mbf" {
            // WCA encodes multi-blind as DDTTTTTMM (points deficit, elapsed seconds, missed cubes).
            let missed = value % 100
            let solved = 99 - (value / 10_000_000 % 100) + missed
            let seconds = value / 100 % 100_000
            let time = seconds == 99_999 ? "time unlisted" : clock(seconds: seconds)
            return "\(solved)/\(solved + missed) · \(time)"
        }
        let seconds = value / 100
        let time = seconds >= 60 ? clock(seconds: seconds) : String(seconds)
        return time + String(format: ".%02d", value % 100) + (seconds < 60 ? " s" : "")
    }

    private static func clock(seconds: Int) -> String {
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
