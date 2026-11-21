import Foundation
import Testing
@testable import Observatory

struct ProviderTests {
    private let stock = Monitor(kind: .stock, title: "", symbol: "BRK.B")
    private let flight = Monitor(kind: .flight, title: "", origin: "LHR", destination: "JFK",
                                 departure: "2028-02-29", currency: "EUR")
    private let json = Monitor(kind: .json, title: "", endpoint: "https://feed.example.org/data?unit=C",
                               field: "forecast.0.value")
    private let secret = "fixture-key"

    private func reading(_ monitor: Monitor, body: String, status: Int = 200,
                         inspect: (URLRequest) throws -> Void = { _ in }) async throws -> Reading {
        try await FeedProvider.fetch(monitor, key: secret) { request in
            try inspect(request)
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: status,
                                                       httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
    }

    private func failure(_ work: () async throws -> Reading, contains message: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            _ = try await work()
            Issue.record("Expected a feed error", sourceLocation: sourceLocation)
        } catch {
            #expect(error.localizedDescription.contains(message), sourceLocation: sourceLocation)
            #expect(!String(reflecting: error).contains(secret), sourceLocation: sourceLocation)
        }
    }

    @Test func testFinnhubUsesHeaderAndPreservesMarketTimeAndQuotePrecision() async throws {
        let quote = try await reading(stock, body: #"{"c":1.23456,"pc":1,"t":1582641000}"#) { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://finnhub.io/api/v1/quote?symbol=BRK.B")
            #expect(request.value(forHTTPHeaderField: "X-Finnhub-Token") == self.secret)
            #expect(request.timeoutInterval > 0)
        }
        #expect(quote.value == "1.23456")
        #expect(quote.observedAt.timeIntervalSince1970 == 1_582_641_000)
        #expect(quote.detail.contains("Finnhub"))
    }

    @Test func testFinnhubRejectsMissingPricesAndInvalidMarketTimes() async {
        for body in [#"{"c":0,"t":0}"#, #"{"c":true,"t":1582641000}"#, #"{"c":2}"#,
                     #"{"c":2,"t":1582641000000}"#] {
            await failure({ try await self.reading(self.stock, body: body) }, contains: "market quote")
        }
    }

    @Test func testFlightUsesCheapestPricedOfferAcrossBothGroupsAndSearchTime() async throws {
        let body = """
        {"search_metadata":{"status":"Success","processed_at":"2023-10-02 05:42:48 UTC"},
         "search_parameters":{"currency":"EUR"}, "best_flights":[{"price":230},{"price":210}],
         "other_flights":[{},{"price":null},{"price":false},{"price":0},{"price":20,"type":"Round trip"},{"price":191,"type":"One way"}],
         "price_insights":{"lowest_price":140}}
        """
        let fare = try await reading(flight, body: body) { request in
            let url = try #require(request.url)
            #expect(url.host() == "serpapi.com")
            #expect(url.path() == "/search.json")
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let items = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
            #expect(items["engine"] == "google_flights")
            #expect(items["type"] == "2")
            #expect(items["no_cache"] == "true")
            #expect(items["sort_by"] == "2")
            #expect(items["departure_id"] == "LHR")
            #expect(items["arrival_id"] == "JFK")
            #expect(items["outbound_date"] == "2028-02-29")
            #expect(items["currency"] == "EUR")
            #expect(items["return_date"] == nil)
            #expect(items["api_key"] == self.secret)
        }
        #expect(fare.value == "EUR 191")
        #expect(fare.observedAt == ISO8601DateFormatter().date(from: "2023-10-02T05:42:48Z"))
        #expect(fare.detail.contains("Google Flights via SerpApi"))
        #expect(!fare.detail.contains(secret))
    }

    @Test func exactFlightDoesNotUseACheaperDifferentService() async throws {
        var target = flight
        target.flightNumber = "BA117"
        let body = """
        {"search_metadata":{"status":"Success","processed_at":"2023-10-02 05:42:48 UTC"},
         "best_flights":[{"price":120,"flights":[{"flight_number":"BA 113"}]},
                         {"price":260,"flights":[{"flight_number":"BA 117"}]}]}
        """
        let result = try await reading(target, body: body)
        #expect(result.value == "EUR 260")
        target.flightNumber = "BA119"
        await failure({ try await self.reading(target, body: body) }, contains: "BA119")
    }

    @Test func testFlightRejectsIncompleteSearchesMissingOffersAndWrongCurrency() async {
        let future = """
        {"search_metadata":{"status":"Success","processed_at":"2099-01-01 00:00:00 UTC"},"other_flights":[{"price":200}]}
        """
        await failure({ try await self.reading(self.flight, body: future) }, contains: "timestamp")
        await failure({ try await self.reading(self.flight, body: #"{"search_metadata":{"status":"Processing"}}"#) },
                      contains: "completed")
        await failure({ try await self.reading(self.flight, body: #"{"search_metadata":{"status":"Success"},"price_insights":{"lowest_price":32}}"#) },
                      contains: "No priced")
        await failure({ try await self.reading(self.flight, body: #"{"search_metadata":{"status":"Success"},"search_parameters":{"currency":"JPY"}}"#) },
                      contains: "currency")
    }

    @Test func testPublicJSONUsesReceiptTimeAndSendsNoCredentials() async throws {
        for (body, expected) in [(#"{"forecast":[{"value":true}]}"#, "true"),
                                 (#"{"forecast":[{"value":0}]}"#, "0"),
                                 (#"{"forecast":[{"value":"clear"}]}"#, "clear")] {
            var received = Date.distantFuture
            let field = try await reading(json, body: body) { request in
                received = .now
                #expect(request.url?.absoluteString == self.json.endpoint)
                #expect(request.value(forHTTPHeaderField: "X-Finnhub-Token") == nil)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(!request.url!.absoluteString.contains(self.secret))
            }
            #expect(field.value == expected)
            #expect(field.observedAt >= received && field.observedAt <= .now)
            #expect(field.detail.contains("feed.example.org"))
            #expect(!field.detail.contains("unit="))
        }
    }

    @Test func testPublicJSONRejectsMissingAndNonscalarFields() async {
        await failure({ try await self.reading(self.json, body: #"{"forecast":[]}"#) }, contains: "not found")
        await failure({ try await self.reading(self.json, body: #"{"forecast":[{"value":null}]}"#) }, contains: "field")
        await failure({ try await self.reading(self.json, body: #"{"forecast":[{"value":{}}]}"#) }, contains: "field")
    }

    @Test func testInvalidSettingsFailBeforeTransport() async {
        func rejected(_ monitor: Monitor, key: String?, message: String) async {
            await failure({
                try await FeedProvider.fetch(monitor, key: key) { _ in
                    Issue.record("Transport was called for invalid settings")
                    throw URLError(.badURL)
                }
            }, contains: message)
        }
        for endpoint in ["http://example.com", "https://localhost", "https://[::1]", "https://10.1.2.3",
                         "https://192.0.2.1", "https://[2001:db8::1]",
                         "https://user:password@example.org/data", "https://printer.local"] {
            var monitor = json
            monitor.endpoint = endpoint
            await rejected(monitor, key: nil, message: "HTTPS")
        }
        var badPath = json
        badPath.field = "forecast..value"
        await rejected(badPath, key: nil, message: "key path")
        var badDate = flight
        badDate.departure = "2027-02-29"
        await rejected(badDate, key: secret, message: "date")
        badDate.departure = "2001-01-01"
        await rejected(badDate, key: secret, message: "passed")
        var unsupported = flight
        unsupported.currency = "BBD"
        await rejected(unsupported, key: secret, message: "currency")
        await rejected(stock, key: " ", message: "Finnhub")
        await rejected(flight, key: nil, message: "SerpApi")
    }

    @Test func testProviderAndTransportFailuresDoNotExposeSecrets() async {
        let echo = "{\"error\":\"\(secret)\"}"
        await failure({ try await self.reading(self.flight, body: echo, status: 429) }, contains: "429")
        await failure({ try await self.reading(self.stock, body: echo, status: 401) }, contains: "401")
        let fareError = """
        {"error":"fixture-key","search_metadata":{"status":"Success","processed_at":"2023-10-02 05:42:48 UTC"},
         "best_flights":[{"price":240}]}
        """
        await failure({ try await self.reading(self.flight, body: fareError) }, contains: "could not complete")
        let quoteError = #"{"error":"fixture-key","c":2,"t":1582641000}"#
        await failure({ try await self.reading(self.stock, body: quoteError) }, contains: "could not complete")
        await failure({ try await self.reading(self.flight, body: self.secret) }, contains: "invalid JSON")
        for (code, message) in [(URLError.Code.timedOut, "timed out"), (.cannotConnectToHost, "connect")] {
            await failure({
                try await FeedProvider.fetch(self.flight, key: self.secret) { request in
                    throw URLError(code, userInfo: [NSURLErrorKey: request.url!])
                }
            }, contains: message)
        }
    }
}
