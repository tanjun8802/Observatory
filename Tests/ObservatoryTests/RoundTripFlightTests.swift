import Foundation
import Testing
@testable import Observatory

struct RoundTripFlightTests {
    private let prompt = "Find round-trip flights from ATL to DFW, departing 2099-02-01 and returning 2099-02-08. One adult in economy. Show the three cheapest itineraries in USD."

    private func monitor(_ prompt: String) -> Monitor { Monitor(kind: .codex, title: "Fare comparison", prompt: prompt) }

    @Test func matchesOnlyTheSupportedTripAndPreservesBothDirectionsInPublicLink() throws {
        let search = try #require(RoundTripFlightFeed.search(for: monitor(prompt)))
        #expect(search.origins == ["ATL"] && search.destinations == ["DFW"] && search.currency == "USD")
        let items = try #require(URLComponents(url: search.publicURL, resolvingAgainstBaseURL: false)?.queryItems)
        var token = try #require(items.first { $0.name == "tfs" }?.value)
        token = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !token.count.isMultiple(of: 4) { token.append("=") }
        let bytes = try #require(Data(base64Encoded: token))
        let decoded = String(decoding: bytes, as: UTF8.self)
        for part in ["2099-02-01", "2099-02-08", "ATL", "DFW"] { #expect(decoded.contains(part)) }
        #expect(items.contains(.init(name: "curr", value: "USD")))
        for extra in [" Singapore Airlines.", " With two adults.", " Plus a child.", " Only nonstop.",
                      " Leave before noon.", " Include a checked bag.", " Return via MAN."] {
            #expect(RoundTripFlightFeed.search(for: monitor(prompt + extra)) == nil)
        }
        #expect(RoundTripFlightFeed.search(for: monitor(prompt.replacingOccurrences(of: "02-08", with: "02-30"))) == nil)
    }

    private func offer(_ origin: String, _ destination: String, date: String, hour: Int, price: Int, token: String? = nil) -> [String: Any] {
        let flight: [String: Any] = [
            "airline": "Fixture Air", "flight_number": "XA \(hour)", "travel_class": "Economy",
            "departure_airport": ["id": origin, "time": "\(date) \(hour):00"],
            "arrival_airport": ["id": destination, "time": "\(date) \(hour):55"]
        ]
        var result: [String: Any] = ["type": "Round trip", "price": price, "flights": [flight], "total_duration": 55]
        result["departure_token"] = token
        return result
    }

    private func page(_ offers: [[String: Any]], token: String? = nil, currency: String = "USD") throws -> Data {
        var echo: [String: Any] = ["departure_id": "ATL", "arrival_id": "DFW", "outbound_date": "2099-02-01",
                                  "return_date": "2099-02-08", "currency": currency, "travel_class": 1]
        echo["departure_token"] = token
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(secondsFromGMT: 0)
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return try JSONSerialization.data(withJSONObject: [
            "search_metadata": ["status": "Success", "processed_at": stamp.string(from: .now)],
            "search_parameters": echo, "other_flights": offers
        ])
    }

    @Test func verifiesCompleteReturnsRanksDistinctPairsAndBoundsRequests() async throws {
        let first = (10...14).map { offer("ATL", "DFW", date: "2099-02-01", hour: $0, price: $0, token: "out-\($0)") }
        var tokens: [String?] = []
        let reading = try await FeedProvider.fetch(monitor(prompt), key: "fixture") { request in
            let url = try #require(request.url)
            let parameters = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(parameters["type"] == "1" && parameters["adults"] == "1" && parameters["return_date"] == "2099-02-08")
            let token = parameters["departure_token"]
            tokens.append(token)
            let data: Data
            switch token {
            case nil: data = try page(first)
            case "out-10": data = try page([], token: token, currency: "JPY")
            default:
                let price = token == "out-11" ? 135 : 120
                let back = offer("DFW", "ATL", date: "2099-02-08", hour: 11, price: price)
                let wrong = offer("DFW", "ATL", date: "2099-02-09", hour: 11, price: 5)
                data = try page([wrong, back, back], token: token)
            }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(tokens == [nil, "out-10", "out-11", "out-12"])
        #expect(reading.presentation?.rows?.map(\.title) == ["1. USD 120 return", "2. USD 135 return"])
        #expect(reading.presentation?.isPartial == true)
        #expect(reading.presentation?.rows?.first?.detail.contains("DFW 2099-02-08") == true)
    }

    @Test func missingCredentialAndRateLimitDoNotTriggerMoreRequests() async {
        var requests = 0
        do {
            _ = try await FeedProvider.fetch(monitor(prompt), key: nil) { _ in fatalError("Unexpected search") }
            Issue.record("Expected a credential error")
        } catch { #expect(error.localizedDescription.contains("API key is required")) }
        do {
            _ = try await FeedProvider.fetch(monitor(prompt), key: "fixture") { request in
                requests += 1
                let out = (10...12).map { offer("ATL", "DFW", date: "2099-02-01", hour: $0, price: $0, token: "out-\($0)") }
                return (try page(out), HTTPURLResponse(url: request.url!, statusCode: requests == 1 ? 200 : 429,
                                                      httpVersion: nil, headerFields: nil)!)
            }
            Issue.record("Expected a provider limit")
        } catch { #expect(error.localizedDescription.contains("429")) }
        #expect(requests == 2)
    }
}
