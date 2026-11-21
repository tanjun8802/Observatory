import Foundation

/// Current modelled conditions for Brixworth village, West Northamptonshire (GeoNames 2654660).
enum WeatherFeed {
    private static let latitude = 52.32912
    private static let longitude = -0.9035
    private static let locality = "Brixworth, Northamptonshire, UK"

    private enum Unit: String {
        case celsius, fahrenheit
        var symbol: String { self == .celsius ? "°C" : "°F" }
    }

    // Match the prompt itself. Titles are editable, and other weather tasks still need Codex.
    private static let vocabulary = Set("""
        a access air an and are as at brixworth c celsius centigrade condition conditions
        current currently degrees degree display england english f fahrenheit find for from get
        give in is it kingdom latest like local me northamptonshire now of only outside please
        present provide read reliable report retrieve right s show source sourced tell temp temperature
        the to today uk united use using weather west what
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    private static func requestedUnit(_ monitor: Monitor) -> Unit? {
        guard monitor.kind == .codex, let prompt = monitor.prompt else { return nil }
        let words = Set(prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard words.contains("brixworth"),
              !words.isDisjoint(with: ["weather", "temperature", "temp", "conditions"]),
              words.isSubset(of: vocabulary) else { return nil }
        let celsius = !words.isDisjoint(with: ["celsius", "centigrade", "c"])
        let fahrenheit = !words.isDisjoint(with: ["fahrenheit", "f"])
        guard !(celsius && fahrenheit) else { return nil }
        return fahrenheit ? .fahrenheit : .celsius
    }

    static func matches(_ monitor: Monitor) -> Bool { requestedUnit(monitor) != nil }

    static func fetch(_ monitor: Monitor) async throws -> Reading {
        try await fetch(monitor, now: { Date() }) { request in
            try await URLSession.shared.data(for: request)
        }
    }

    static func fetch(_ monitor: Monitor, now: () -> Date,
                      load: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Reading {
        guard let unit = requestedUnit(monitor) else {
            throw CodexError("This feed does not describe current weather in Brixworth.")
        }
        let url = URL(string: "https://api.open-meteo.com/v1/forecast")!.appending(queryItems: [
            .init(name: "latitude", value: String(latitude)), .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "temperature_unit", value: unit.rawValue), .init(name: "timeformat", value: "unixtime")
        ])
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let (data, response) = try await load(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CodexError("Open-Meteo could not supply the current weather for Brixworth.")
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              abs(payload.latitude - latitude) <= 0.1, abs(payload.longitude - longitude) <= 0.1,
              payload.current_units.time == "unixtime", payload.current_units.temperature_2m == unit.symbol,
              payload.current_units.weather_code == "wmo code", payload.current.temperature_2m.isFinite,
              (0...1).contains(payload.current.is_day),
              let (condition, symbol) = conditions(payload.current.weather_code, day: payload.current.is_day == 1) else {
            throw CodexError("Open-Meteo returned incomplete or unexpected weather data for Brixworth.")
        }

        // Open-Meteo's current endpoint samples 15-minute model fields. Keep their valid time
        // and reject stale caches rather than giving an old temperature a new timestamp.
        let validTime = Date(timeIntervalSince1970: TimeInterval(payload.current.time))
        guard (-300...3600).contains(now().timeIntervalSince(validTime)) else {
            throw CodexError("Open-Meteo has no recent current-weather estimate for Brixworth.")
        }
        let temperature = payload.current.temperature_2m
        let presentation = FeedPresentation(kind: .weather, location: locality, condition: condition,
                                            weatherSymbol: symbol,
                                            metrics: [.init(label: "Temperature", value: temperature, unit: unit.symbol)],
                                            sourceName: "Open-Meteo (model estimate)", sourceURL: url)
        let display = temperature.formatted(.number.precision(.fractionLength(0...1)))
        let stamp = validTime.formatted(.iso8601)
        return Reading(value: "\(locality): \(display)\(unit.symbol), \(condition.lowercased()). Open-Meteo model estimate for \(stamp).",
                       detail: "Open-Meteo current weather model estimate", observedAt: validTime,
                       presentation: presentation)
    }

    private struct Payload: Decodable {
        let latitude, longitude: Double
        let current: Current
        let current_units: Units
        struct Current: Decodable {
            let time, weather_code, is_day: Int
            let temperature_2m: Double
        }
        struct Units: Decodable {
            let time, weather_code, temperature_2m: String
        }
    }

    // WMO weather interpretation codes published at https://open-meteo.com/en/docs
    private static func conditions(_ code: Int, day: Bool) -> (String, String)? {
        switch code {
        case 0: return ("Clear sky", day ? "sun.max.fill" : "moon.stars.fill")
        case 1: return ("Mainly clear", day ? "cloud.sun.fill" : "cloud.moon.fill")
        case 2: return ("Partly cloudy", day ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return ("Overcast", "cloud.fill")
        case 45: return ("Fog", "cloud.fog.fill")
        case 48: return ("Depositing rime fog", "cloud.fog.fill")
        case 51, 53, 55: return ("Drizzle", "cloud.drizzle.fill")
        case 56, 57: return ("Freezing drizzle", "cloud.sleet.fill")
        case 61: return ("Light rain", "cloud.rain.fill")
        case 63: return ("Moderate rain", "cloud.rain.fill")
        case 65: return ("Heavy rain", "cloud.heavyrain.fill")
        case 66, 67: return ("Freezing rain", "cloud.sleet.fill")
        case 71, 73, 75: return ("Snow", "cloud.snow.fill")
        case 77: return ("Snow grains", "cloud.snow.fill")
        case 80, 81, 82: return ("Rain showers", "cloud.rain.fill")
        case 85, 86: return ("Snow showers", "cloud.snow.fill")
        case 95: return ("Thunderstorm", "cloud.bolt.rain.fill")
        case 96, 99: return ("Thunderstorm with hail", "cloud.hail.fill")
        default: return nil
        }
    }
}
