import Foundation

/// A fixed-date, one-adult economy fare comparison. Other requests retain the general Codex path.
struct RoundTripFlightSearch {
    let origins: [String]
    let destinations: [String]
    let outbound: String
    let returning: String
    let currency: String

    var publicURL: URL {
        // Google Flights' public share URL uses two dated legs, one adult and economy class.
        // The framing matches the round-trip URL published in SerpApi's Google Flights reference.
        func field(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] {
            var size = bytes.count
            var prefix = [tag]
            while size >= 128 {
                prefix.append(UInt8(size % 128) | 128)
                size /= 128
            }
            return prefix + [UInt8(size)] + bytes
        }
        func leg(_ date: String, _ from: [String], _ to: [String]) -> [UInt8] {
            func airport(_ code: String) -> [UInt8] { [8, 1] + field(18, Array(code.utf8)) }
            let departures = from.flatMap { field(106, airport($0)) }
            let arrivals = to.flatMap { field(114, airport($0)) }
            return field(26, field(18, Array(date.utf8)) + departures + arrivals)
        }
        var parameters: [UInt8] = [8, 28, 16, 2]
        parameters += leg(outbound, origins, destinations)
        parameters += leg(returning, destinations, origins)
        parameters += [66, 1, 1, 72, 1, 112, 1, 152, 1, 1, 200, 1, 1]
        let token = Data(parameters).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "https://www.google.com/travel/flights")!.appending(queryItems: [
            .init(name: "tfs", value: token), .init(name: "curr", value: currency),
            .init(name: "gl", value: "gb"), .init(name: "hl", value: "en"), .init(name: "tfu", value: "EgIIAg")
        ])
    }
}

enum RoundTripFlightFeed {
    static func search(for monitor: Monitor) -> RoundTripFlightSearch? {
        guard monitor.kind == .codex, let prompt = monitor.prompt else { return nil }
        let text = prompt.replacingOccurrences(of: "–", with: "-")
        let lower = text.lowercased()
        guard lower.range(of: #"\bround[- ]trip\b"#, options: .regularExpression) != nil,
              lower.contains("flight"), lower.range(of: #"\b(?:three|3) cheapest\b"#, options: .regularExpression) != nil,
              lower.range(of: #"\b(?:one|1) adult\b"#, options: .regularExpression) != nil,
              lower.contains("economy") else { return nil }
        // This adapter supports open-jaw-free return trips, without airline, stop, budget or time filters.
        let restriction = #"\b(?:only|under|below|less than|at most|at least|before|after|between|morning|afternoon|evening|overnight|nonstop|non-stop|direct|avoid|exclude|without|via|maximum|minimum|prefer|must|nonrefundable|refundable|flexible|premium|business|first class|children|child|infants?|one stop|[0-9]+ stops?|checked bag required)\b"#
        guard lower.range(of: restriction, options: .regularExpression) == nil else { return nil }
        let datePattern = #"(\d{4}-\d{2}-\d{2}|\d{1,2} [A-Za-z]+ \d{4})"#
        let route = #"\bfrom\s+([^,\n]+?)\s+to\s+([^,\n]+?)[,\s]+departing\s+(?:on\s+)?"#
        let pattern = "(?i)" + route + datePattern + #"[,]?\s+(?:and\s+)?returning\s+(?:on\s+)?"# + datePattern + #"\b"#
        guard let groups = captures(pattern, text), let origins = airports(groups[0]), let destinations = airports(groups[1]),
              Set(origins).isDisjoint(with: destinations), let outbound = isoDate(groups[2]), let returning = isoDate(groups[3]),
              outbound <= returning else { return nil }
        guard let currency = captures(#"\b(?:in|currency)\s+([A-Z]{3})\b"#, text)?.first,
              FlightCurrency.supported.contains(currency) else { return nil }
        // Match only understood reporting language outside the verified route and dates.
        // Unknown carrier names, cabin/passenger combinations and extra filters stay with Codex.
        let reporting = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
            .replacingOccurrences(of: currency, with: " ")
        let words = reporting.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard words.allSatisfy(reportingWords.contains) else { return nil }
        return RoundTripFlightSearch(origins: origins, destinations: destinations, outbound: outbound,
                                     returning: returning, currency: currency)
    }

    private static let reportingWords: Set<String> = Set("""
        at each refresh check search find compare track current live the cheapest lowest priced round trip flight flights
        fare fares listing listings for assume one 1 single adult passenger travelling traveling in economy class
        show return give three 3 distinct options itineraries itinerary ranked table list with total price prices per person
        including taxes and mandatory fees each option include airlines airline numbers number airports airport local departure
        arrival dates date times time travel way stops stop layover layovers duration durations included baggage allowance
        booking provider link links when were checked london if fewer than are available you could verify verified results
        departure return both legs currency a the of to on their as an
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    private static func airports(_ place: String) -> [String]? {
        let name = place.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["london", "lon", "any london airport", "all london airports", "london (lon)"].contains(name.lowercased()) {
            return ["LHR", "LGW", "LCY", "LTN", "STN", "SEN"]
        }
        guard let code = captures(#"^(?:[\p{L} '-]+\s+\(([A-Z]{3})\)|([A-Z]{3}))$"#, name)?.first else { return nil }
        return [code]
    }

    private static func isoDate(_ text: String) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["yyyy-MM-dd", "d MMMM yyyy", "d MMM yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text), formatter.string(from: date).caseInsensitiveCompare(text) == .orderedSame {
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
        }
        return nil
    }
}

extension RoundTripFlightFeed {
    private enum UnusableSelection: String, LocalizedError {
        case incomplete = "SerpApi did not return a completed round-trip search."
        case parameters = "The provider returned different flight search parameters."
        case stale = "The provider could not confirm a fresh quote."
        var errorDescription: String? { rawValue }
    }

    private struct Page: Decodable {
        struct Metadata: Decodable { let status: String; let processedAt: String }
        struct Parameters: Decodable {
            let departureId, arrivalId, outboundDate, returnDate, currency: String
            let departureToken: String?
            let adults, travelClass: Int?
        }
        let searchMetadata: Metadata
        let searchParameters: Parameters
        let bestFlights, otherFlights: [Offer]?
    }

    private struct Offer: Decodable {
        struct Stop: Decodable { let id: String; let time: String }
        struct Leg: Decodable {
            let departureAirport, arrivalAirport: Stop
            let airline, flightNumber: String?
            let travelClass: String?
        }
        struct Layover: Decodable { let id: String?; let duration: Int? }
        let flights: [Leg]?
        let layovers: [Layover]?
        let price: Double?
        let totalDuration: Int?
        let type, departureToken: String?
        let extensions: [String]?

        func matches(from: [String], to: [String], date: String) -> Bool {
            guard type?.lowercased() == "round trip", let price, price.isFinite, price > 0,
                  let flights, let first = flights.first, let last = flights.last,
                  from.contains(first.departureAirport.id), to.contains(last.arrivalAirport.id),
                  first.departureAirport.time.hasPrefix(date + " "),
                  flights.allSatisfy({ $0.travelClass?.lowercased() == "economy" }) else { return false }
            return zip(flights, flights.dropFirst()).allSatisfy { $0.arrivalAirport.id == $1.departureAirport.id }
        }

        var identity: String {
            (flights ?? []).map {
                [$0.departureAirport.id, $0.departureAirport.time, $0.arrivalAirport.id, $0.arrivalAirport.time]
                    .joined(separator: " ")
            }.joined(separator: " / ")
        }

        func description(_ direction: String) -> String {
            let legs = flights ?? []
            let duration = totalDuration.map { "\($0 / 60)h \($0 % 60)m" } ?? "duration unavailable"
            let count = max(0, legs.count - 1)
            var lines = ["\(direction) · \(duration) · \(count) \(count == 1 ? "stop" : "stops")"]
            for (index, leg) in legs.enumerated() {
                lines.append("\(leg.airline ?? "Airline unavailable") \(leg.flightNumber ?? "(number unavailable)") · \(leg.departureAirport.id) \(leg.departureAirport.time) → \(leg.arrivalAirport.id) \(leg.arrivalAirport.time)")
                if index < count {
                    let stop = layovers?.first { $0.id == leg.arrivalAirport.id }
                    lines.append("Layover at \(leg.arrivalAirport.id) · " + (stop?.duration.map { "\($0 / 60)h \($0 % 60)m" } ?? "duration unavailable"))
                }
            }
            let bags = (extensions ?? []).filter { $0.localizedCaseInsensitiveContains("bag") || $0.localizedCaseInsensitiveContains("carry-on") }
            lines.append("Baggage · " + (bags.isEmpty ? "allowance unverified" : bags.joined(separator: ", ")))
            return lines.joined(separator: "\n")
        }
    }

    static func fetch(_ search: RoundTripFlightSearch, key: String,
                      load: (URLRequest) async throws -> Data) async throws -> Reading {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = TimeZone(identifier: "Europe/London")
        clock.dateFormat = "yyyy-MM-dd"
        guard search.outbound >= clock.string(from: .now) else { throw CodexError("The outbound date has passed. Edit the feed dates.") }
        let origins = search.origins.joined(separator: ",")
        let destinations = search.destinations.joined(separator: ",")
        let requested = ["engine": "google_flights", "type": "1", "departure_id": origins, "arrival_id": destinations,
                         "outbound_date": search.outbound, "return_date": search.returning, "adults": "1",
                         "travel_class": "1", "currency": search.currency, "hl": "en", "gl": "uk", "sort_by": "2",
                         "deep_search": "true", "show_hidden": "true", "no_cache": "true", "api_key": key]

        func offers(for token: String?) async throws -> [Offer] {
            var query = requested
            query["departure_token"] = token
            let url = URL(string: "https://serpapi.com/search.json")!.appending(queryItems: query.map(URLQueryItem.init))
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 75)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            try Task.checkCancellation()
            let data = try await load(request)
            try Task.checkCancellation()
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let page = try? decoder.decode(Page.self, from: data), page.searchMetadata.status == "Success" else {
                throw UnusableSelection.incomplete
            }
            let parameters = page.searchParameters
            guard parameters.departureId == origins, parameters.arrivalId == destinations,
                  parameters.outboundDate == search.outbound, parameters.returnDate == search.returning,
                  parameters.currency == search.currency, (parameters.adults ?? 1) == 1,
                  (parameters.travelClass ?? 1) == 1, parameters.departureToken == token else {
                throw UnusableSelection.parameters
            }
            let utc = DateFormatter()
            utc.locale = Locale(identifier: "en_US_POSIX")
            utc.timeZone = TimeZone(secondsFromGMT: 0)
            utc.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
            guard let checked = utc.date(from: page.searchMetadata.processedAt),
                  (-300...1800).contains(Date.now.timeIntervalSince(checked)) else {
                throw UnusableSelection.stale
            }
            return (page.bestFlights ?? []) + (page.otherFlights ?? [])
        }

        let outbound = try await offers(for: nil).filter {
            $0.departureToken?.isEmpty == false && $0.matches(from: search.origins, to: search.destinations, date: search.outbound)
        }.sorted { ($0.price ?? .infinity) < ($1.price ?? .infinity) }
        var seen = Set<String>()
        let selected = outbound.filter { seen.insert($0.identity).inserted }.prefix(3)
        var combinations: [(out: Offer, back: Offer, price: Double)] = []
        var firstFailure: UnusableSelection?
        for out in selected {
            do {
                for back in try await offers(for: out.departureToken) where back.matches(from: search.destinations, to: search.origins, date: search.returning) {
                    if let price = back.price { combinations.append((out, back, price)) }
                }
            } catch let error as UnusableSelection {
                if firstFailure == nil { firstFailure = error }
            }
        }
        var itineraries = Set<String>()
        let ranked = combinations.sorted { $0.price < $1.price }
            .filter { itineraries.insert($0.out.identity + " | " + $0.back.identity).inserted }.prefix(3)
        guard !ranked.isEmpty else {
            if let firstFailure { throw firstFailure }
            throw CodexError("No complete priced return itinerary was verified. Check the dates in Google Flights.")
        }
        let rows = ranked.enumerated().map { index, pair in
            let amount = pair.price.formatted(.number.precision(.fractionLength(0...2)))
            return FeedRow(title: "\(index + 1). \(search.currency) \(amount) return",
                           detail: pair.out.description("Outbound") + "\n" + pair.back.description("Return"),
                           value: "One adult · Economy")
        }
        let now = Date.now
        clock.dateFormat = "d MMM yyyy, HH:mm z"
        let summary = "Lowest \(rows.count) distinct round-trip fares verified from up to three departures. Prices per adult checked \(clock.string(from: now)) (London). Airport times are local. The search listing does not confirm the final tax and fee breakdown, booking agent, or direct booking link. Open Google Flights to check fare conditions."
        return Reading(value: summary, detail: "Google Flights via SerpApi", observedAt: now,
                       presentation: .init(kind: .list, rows: rows, isPartial: true,
                                           sourceName: "Open these dates in Google Flights", sourceURL: search.publicURL))
    }
}
