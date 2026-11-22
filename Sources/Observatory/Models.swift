import Foundation

enum MonitorKind: String, Codable, CaseIterable, Identifiable {
    case stock, flight, json, codex
    var id: String { rawValue }
}

struct Monitor: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: MonitorKind
    var title: String
    var symbol = ""
    var origin = ""
    var destination = ""
    var flightNumber: String? = nil
    var departure = ""   // YYYY-MM-DD, one way
    var currency = "USD"
    var endpoint = ""
    var field = ""       // dot-separated JSON path
    var prompt: String?
    var schedule: FeedSchedule?
    var createdAt: Date?
    var isPaused = false
    var scheduleAnchor: Date?
    var theme: BoardTheme?
}

extension Monitor {
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try fields.decode(UUID.self, forKey: .id),
                  kind: try fields.decode(MonitorKind.self, forKey: .kind),
                  title: try fields.decode(String.self, forKey: .title),
                  symbol: try fields.decode(String.self, forKey: .symbol),
                  origin: try fields.decode(String.self, forKey: .origin),
                  destination: try fields.decode(String.self, forKey: .destination),
                  flightNumber: try fields.decodeIfPresent(String.self, forKey: .flightNumber),
                  departure: try fields.decode(String.self, forKey: .departure),
                  currency: try fields.decode(String.self, forKey: .currency),
                  endpoint: try fields.decode(String.self, forKey: .endpoint),
                  field: try fields.decode(String.self, forKey: .field),
                  prompt: try fields.decodeIfPresent(String.self, forKey: .prompt),
                  schedule: try fields.decodeIfPresent(FeedSchedule.self, forKey: .schedule),
                  createdAt: try fields.decodeIfPresent(Date.self, forKey: .createdAt),
                  isPaused: try fields.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false,
                  scheduleAnchor: try fields.decodeIfPresent(Date.self, forKey: .scheduleAnchor),
                  theme: try fields.decodeIfPresent(String.self, forKey: .theme).flatMap(BoardTheme.init(rawValue:)))
    }
}

// Google Travel's published currency codes: https://serpapi.com/google-travel-currencies
enum FlightCurrency {
    static let supported = Set("""
        AED ALL AMD ARS AUD AWG AZN BAM BGN BHD BMD BRL BSD BYN CAD CHF CLP CNY COP CRC CUP CZK
        DKK DOP DZD EGP EUR GBP GEL HKD HUF IDR ILS INR IRR ISK JMD JOD JPY KRW KWD KZT LBP MAD
        MDL MKD MXN MYR NOK NZD OMR PAB PEN PHP PKR PLN QAR RON RSD RUB SAR SEK SGD THB TRY TWD
        UAH USD VND XPF ZAR
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
}

struct Reading: Codable, Equatable {
    var value: String
    var detail: String
    var observedAt: Date
    var presentation: FeedPresentation? = nil
}

struct FeedMetric: Codable, Equatable {
    var label: String
    var value: Double
    var unit: String
}

struct FeedRow: Codable, Equatable {
    var title: String
    var detail: String
    var value: String
    var url: String? = nil

    var link: URL? {
        guard let url, let link = URL(string: url, encodingInvalidCharacters: false),
              link.scheme?.lowercased() == "https", let host = link.host(), !host.isEmpty,
              link.user() == nil, link.password() == nil else { return nil }
        return link
    }
}

struct FeedPresentation: Codable, Equatable {
    enum Kind: String, Codable { case weather, metrics, summary, list }

    var kind: Kind
    var location: String? = nil
    var condition: String? = nil
    var weatherSymbol: String? {
        didSet { weatherSymbol = Self.allowedSymbol(weatherSymbol) }
    }
    var metrics: [FeedMetric] = []
    var rows: [FeedRow]? = nil
    var isPartial: Bool? = nil
    var sourceName: String? = nil
    var sourceURL: URL? = nil

    static let weatherSymbols = [
        "sun.max.fill", "moon.stars.fill", "cloud.fill", "cloud.sun.fill", "cloud.moon.fill",
        "cloud.drizzle.fill", "cloud.rain.fill", "cloud.heavyrain.fill", "cloud.bolt.rain.fill",
        "cloud.snow.fill", "cloud.sleet.fill", "cloud.hail.fill", "cloud.fog.fill", "wind"
    ]
    private static func allowedSymbol(_ symbol: String?) -> String? {
        symbol.flatMap { weatherSymbols.contains($0) ? $0 : nil }
    }

    init(kind: Kind, location: String? = nil, condition: String? = nil, weatherSymbol: String? = nil,
         metrics: [FeedMetric] = [], rows: [FeedRow]? = nil, isPartial: Bool? = nil,
         sourceName: String? = nil, sourceURL: URL? = nil) {
        self.kind = kind
        self.location = location
        self.condition = condition
        self.weatherSymbol = Self.allowedSymbol(weatherSymbol)
        self.metrics = metrics
        self.rows = rows
        self.isPartial = isPartial
        self.sourceName = sourceName
        self.sourceURL = sourceURL
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: fields.decode(Kind.self, forKey: .kind),
                      location: fields.decodeIfPresent(String.self, forKey: .location),
                      condition: fields.decodeIfPresent(String.self, forKey: .condition),
                      weatherSymbol: fields.decodeIfPresent(String.self, forKey: .weatherSymbol),
                      metrics: fields.decode([FeedMetric].self, forKey: .metrics),
                      rows: fields.decodeIfPresent([FeedRow].self, forKey: .rows),
                      isPartial: fields.decodeIfPresent(Bool.self, forKey: .isPartial),
                      sourceName: fields.decodeIfPresent(String.self, forKey: .sourceName),
                      sourceURL: fields.decodeIfPresent(URL.self, forKey: .sourceURL))
    }

}

enum Credential: String, CaseIterable {
    case finnhub, serpapi
}

extension Credential {
    var providerName: String {
        switch self {
        case .finnhub: return "Finnhub"
        case .serpapi: return "SerpApi"
        }
    }

}
