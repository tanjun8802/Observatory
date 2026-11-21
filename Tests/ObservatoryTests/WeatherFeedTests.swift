import Foundation
import Testing
@testable import Observatory

struct WeatherFeedTests {
    private let saved = Monitor(kind: .codex, title: "Current Weather in Brixworth", prompt:
        "Retrieve the weather for Brixworth, Northamptonshire, UK, from a reliable weather source. Show the current temperature in degrees Celsius (°C), current conditions. Use read-only access.")
    private let time = Date(timeIntervalSince1970: 1_795_299_300)

    @Test func recognizesSavedPromptWithoutInterceptingOtherTasks() {
        #expect(WeatherFeed.matches(saved))
        var feed = saved
        feed.title = "Home"
        feed.prompt = "What's the current temperature in Brixworth in °F?"
        #expect(WeatherFeed.matches(feed))
        for prompt in [nil, "", "Current weather in Northampton", "Weather tomorrow in Brixworth",
                       "Compare current weather in Brixworth and London", "Weather in Brixworth, Australia",
                       "Retrieve current station observations for Brixworth", "Brixworth air quality",
                       "What's the soil temperature in Brixworth?", "Current weather in Brixworth in kelvin",
                       "Show current weather in Brixworth in both °C and °F",
                       "Summarise the economic effects of weather in Brixworth",
                       "Implement a weather API for Brixworth", "Show the Brixworth weather radar"] {
            feed.title = saved.title
            feed.prompt = prompt
            #expect(!WeatherFeed.matches(feed))
        }
        feed = saved
        feed.kind = .json
        #expect(!WeatherFeed.matches(feed))
    }

    private func fixture(unit: String = "°C", value: Double = 5, code: Int = 3, day: Int = 0,
                         at timestamp: Int = 1_795_299_300, latitude: Double = 52.334866) -> String {
        """
        {"latitude":\(latitude),"longitude":-0.91078186,"current_units":{"time":"unixtime","interval":"seconds",
        "temperature_2m":"\(unit)","weather_code":"wmo code","is_day":""},"current":{"time":\(timestamp),
        "interval":900,"temperature_2m":\(value),"weather_code":\(code),"is_day":\(day)}}
        """
    }

    private func read(_ body: String, monitor: Monitor? = nil, status: Int = 200,
                      inspect: (URLRequest) throws -> Void = { _ in }) async throws -> Reading {
        try await WeatherFeed.fetch(monitor ?? saved, now: { time.addingTimeInterval(43) }) { request in
            try inspect(request)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
    }

    @Test func savedFeedGetsVillageModelConditionsAndProviderTimestamp() async throws {
        let reading = try await read(fixture()) { request in
            let url = try #require(request.url)
            #expect(url.scheme == "https" && url.host == "api.open-meteo.com")
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let items = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
            #expect(items["latitude"] == "52.32912" && items["longitude"] == "-0.9035")
            #expect(items["temperature_unit"] == "celsius" && items["timeformat"] == "unixtime")
            #expect(items["current"] == "temperature_2m,weather_code,is_day")
        }
        let card = try #require(reading.presentation)
        #expect(card.kind == .weather && card.location == "Brixworth, Northamptonshire, UK")
        #expect(card.condition == "Overcast" && card.weatherSymbol == "cloud.fill")
        #expect(card.metrics == [FeedMetric(label: "Temperature", value: 5, unit: "°C")])
        #expect(reading.observedAt == time && reading.value.contains("model estimate"))
        #expect(card.sourceName == "Open-Meteo (model estimate)")
        #expect(card.sourceURL?.host == "api.open-meteo.com")
    }

    @Test func fahrenheitAndNightConditionsUseSourceValues() async throws {
        var feed = saved
        feed.prompt = "Brixworth current weather in Fahrenheit"
        let result = try await read(fixture(unit: "°F", value: 40.1, code: 0), monitor: feed) { request in
            #expect(request.url?.query()?.contains("temperature_unit=fahrenheit") == true)
        }
        #expect(result.presentation?.metrics.first == FeedMetric(label: "Temperature", value: 40.1, unit: "°F"))
        #expect(result.presentation?.weatherSymbol == "moon.stars.fill")
        #expect(result.value.contains("40.1°F"))
    }

    @Test func rejectsStaleFutureMalformedOrMislocatedData() async throws {
        for body in [fixture(at: 1_795_200_000), fixture(at: 1_795_399_300), fixture(latitude: 51.5),
                     fixture(day: 2), fixture(code: 100), fixture(unit: "°F"), "{}",
                     fixture().replacingOccurrences(of: "\"temperature_2m\":5.0", with: "\"temperature_2m\":null")] {
            await #expect(throws: CodexError.self) { try await read(body) }
        }
        await #expect(throws: CodexError.self) { try await read(fixture(), status: 429) }
    }
}
