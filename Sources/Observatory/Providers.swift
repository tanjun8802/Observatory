import Foundation
import Darwin

private struct FeedError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class FeedSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

enum FeedProvider {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: FeedSessionDelegate(), delegateQueue: nil)
    }()
    private static let maximumSize = 4 * 1024 * 1024

    static func fetch(_ monitor: Monitor, key: String?) async throws -> Reading {
        if monitor.kind == .codex {
            guard let prompt = monitor.prompt, !prompt.isEmpty else { throw FeedError("This feed needs a prompt.") }
            if WeatherFeed.matches(monitor) { return try await WeatherFeed.fetch(monitor) }
            if WCALiveFeed.matches(monitor) { return try await WCALiveFeed.fetch(monitor) }
            if CodexUsageFeed.matches(monitor) { return try await CodexUsageFeed.fetch(monitor) }
            return try await CodexReading.fetch(prompt: prompt)
        }
        return try await fetch(monitor, key: key) { request in
            if monitor.kind == .json {
                guard let host = request.url?.host(), await publicAddressesOnly(host) else {
                    throw FeedError("The JSON host must resolve to a public internet address.")
                }
            }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try validate(response)
            guard response.expectedContentLength <= Int64(maximumSize) else {
                throw FeedError("The feed response is too large.")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumSize else { throw FeedError("The feed response is too large.") }
                data.append(byte)
            }
            return (data, response)
        }
    }

    // The transport is replaceable so fixtures exercise the same request and response handling.
    static func fetch(_ monitor: Monitor, key: String?,
                      load: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Reading {
        let request = try makeRequest(monitor, key: key)
        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await load(request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FeedError {
            try Task.checkCancellation()
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw FeedError("The feed request timed out.")
        } catch {
            // URL loading errors can contain the complete SerpApi URL, including its API key.
            throw FeedError("Could not connect to the feed.")
        }
        let receivedAt = Date()
        try validate(response)
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw FeedError("The feed returned invalid JSON.")
        }
        switch monitor.kind {
        case .codex: throw FeedError("Codex feeds use the local Codex connection.")
        case .stock:
            let object = try providerObject(json, provider: "Finnhub")
            guard let price = positiveNumber(object["c"]), let timestamp = positiveNumber(object["t"]),
                  timestamp.doubleValue.rounded() == timestamp.doubleValue,
                  timestamp.doubleValue <= receivedAt.timeIntervalSince1970 + 300 else {
                throw FeedError("Finnhub returned no valid market quote for this symbol.")
            }
            return Reading(value: price.stringValue, detail: "Finnhub · \(monitor.symbol.uppercased()) · market quote",
                           observedAt: Date(timeIntervalSince1970: timestamp.doubleValue))
        case .flight:
            return try flightReading(json, monitor: monitor)
        case .json:
            return try jsonReading(json, monitor: monitor, host: request.url!.host()!, receivedAt: receivedAt)
        }
    }

    private static func makeRequest(_ monitor: Monitor, key: String?) throws -> URLRequest {
        var url: URL
        var token: String?
        switch monitor.kind {
        case .codex: throw FeedError("Codex feeds use the local Codex connection.")
        case .stock:
            let symbol = monitor.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !symbol.isEmpty else { throw FeedError("Enter a stock symbol.") }
            token = try requiredKey(key, provider: "Finnhub")
            url = URL(string: "https://finnhub.io/api/v1/quote")!
                .appending(queryItems: [URLQueryItem(name: "symbol", value: symbol)])
        case .flight:
            let origin = monitor.origin.uppercased()
            let destination = monitor.destination.uppercased()
            let currency = monitor.currency.uppercased()
            func isCode(_ value: String) -> Bool {
                value.utf8.count == 3 && value.utf8.allSatisfy { (65...90).contains($0) }
            }
            guard isCode(origin), isCode(destination), origin != destination else {
                throw FeedError("Enter different three-letter departure and arrival airport codes.")
            }
            guard FlightCurrency.supported.contains(currency) else {
                throw FeedError("Choose a supported Google Flights currency.")
            }
            let formatter = utcFormatter("yyyy-MM-dd")
            guard let date = formatter.date(from: monitor.departure),
                  formatter.string(from: date) == monitor.departure else {
                throw FeedError("Enter a valid departure date in YYYY-MM-DD format.")
            }
            let localDate = utcFormatter("yyyy-MM-dd")
            localDate.timeZone = .current
            guard monitor.departure >= localDate.string(from: Date()) else {
                throw FeedError("The departure date has passed.")
            }
            url = URL(string: "https://serpapi.com/search.json")!.appending(queryItems: [
                .init(name: "engine", value: "google_flights"), .init(name: "type", value: "2"),
                .init(name: "departure_id", value: origin), .init(name: "arrival_id", value: destination),
                .init(name: "outbound_date", value: monitor.departure), .init(name: "currency", value: currency),
                .init(name: "sort_by", value: "2"), .init(name: "show_hidden", value: "true"),
                .init(name: "deep_search", value: "true"), .init(name: "no_cache", value: "true"),
                .init(name: "api_key", value: try requiredKey(key, provider: "SerpApi"))
            ])
            if let number = monitor.flightNumber {
                url = url.appending(queryItems: [
                    .init(name: "include_airlines", value: String(number.prefix(2))),
                    .init(name: "stops", value: "1")
                ])
            }
        case .json:
            guard let endpoint = URL(string: monitor.endpoint, encodingInvalidCharacters: false),
                  endpoint.scheme?.lowercased() == "https", let host = endpoint.host(), !host.isEmpty,
                  endpoint.user() == nil, endpoint.password() == nil, endpoint.fragment() == nil,
                  validHost(host) else {
                throw FeedError("Enter a public HTTPS JSON URL without embedded credentials or a fragment.")
            }
            let path = monitor.field.components(separatedBy: ".")
            guard path.allSatisfy({ !$0.isEmpty }) else { throw FeedError("Enter a dot-separated JSON key path.") }
            url = endpoint
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: monitor.kind == .flight ? 75 : 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Finnhub-Token") }
        return request
    }

    private static func requiredKey(_ key: String?, provider: String) throws -> String {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw FeedError("Enter a valid \(provider) API key.")
        }
        return key
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw FeedError("Invalid HTTP response.") }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw FeedError("The provider denied access (HTTP \(http.statusCode)).")
        case 429: throw FeedError("The provider's request limit was reached (HTTP 429).")
        default: throw FeedError("The feed returned HTTP \(http.statusCode).")
        }
    }

    private static func providerObject(_ json: Any, provider: String) throws -> [String: Any] {
        guard let object = json as? [String: Any], object["error"] == nil else {
            throw FeedError("\(provider) could not complete the request.")
        }
        return object
    }

    private static func positiveNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        return number
    }

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static func flightReading(_ json: Any, monitor: Monitor) throws -> Reading {
        let result = try providerObject(json, provider: "SerpApi")
        let currency = monitor.currency.uppercased()
        guard let metadata = result["search_metadata"] as? [String: Any],
              metadata["status"] as? String == "Success" else {
            throw FeedError("SerpApi did not return a completed flight search.")
        }
        if let parameters = result["search_parameters"] as? [String: Any] {
            if let returned = parameters["currency"] as? String, returned.uppercased() != currency {
                throw FeedError("The returned flight currency differs from the requested currency.")
            }
            for (key, expected) in [("departure_id", monitor.origin.uppercased()),
                                    ("arrival_id", monitor.destination.uppercased()),
                                    ("outbound_date", monitor.departure)] {
                if let returned = parameters[key] as? String, returned != expected {
                    throw FeedError("The returned flight route or date differs from the request.")
                }
            }
        }
        var prices: [NSNumber] = []
        for group in ["best_flights", "other_flights"] {
            guard let entries = result[group] else { continue }
            guard let offers = entries as? [[String: Any]] else { throw FeedError("Invalid flight results.") }
            for offer in offers {
                if let type = offer["type"] as? String,
                   type.lowercased().replacingOccurrences(of: "-", with: " ") != "one way" { continue }
                if let target = monitor.flightNumber {
                    guard let legs = offer["flights"] as? [[String: Any]], legs.count == 1,
                          let number = legs[0]["flight_number"] as? String,
                          number.replacingOccurrences(of: " ", with: "").uppercased() == target else { continue }
                }
                if let price = positiveNumber(offer["price"]) { prices.append(price) }
            }
        }
        guard let cheapest = prices.min(by: { $0.compare($1) == .orderedAscending }) else {
            if let number = monitor.flightNumber { throw FeedError("No priced offer was returned for \(number).") }
            throw FeedError("No priced one-way flights were returned.")
        }
        guard let stamp = metadata["processed_at"] as? String,
              let observedAt = utcFormatter("yyyy-MM-dd HH:mm:ss 'UTC'").date(from: stamp),
              observedAt <= Date.now.addingTimeInterval(300) else {
            throw FeedError("SerpApi returned an invalid search timestamp.")
        }
        let route = "\(monitor.origin.uppercased()) → \(monitor.destination.uppercased())"
        let service = monitor.flightNumber ?? "one way"
        return Reading(value: "\(currency) \(cheapest.stringValue)",
                       detail: "Google Flights via SerpApi · \(route) · \(monitor.departure) · \(service)",
                       observedAt: observedAt)
    }

    private static func jsonReading(_ root: Any, monitor: Monitor, host: String, receivedAt: Date) throws -> Reading {
        var field = root
        for part in monitor.field.components(separatedBy: ".") {
            if let object = field as? [String: Any], let child = object[part] {
                field = child
            } else if let array = field as? [Any], let index = Int(part), array.indices.contains(index) {
                field = array[index]
            } else {
                throw FeedError("The JSON key path was not found.")
            }
        }
        let value: String
        if let string = field as? String {
            value = string
        } else if let number = field as? NSNumber {
            value = CFGetTypeID(number) == CFBooleanGetTypeID() ? String(number.boolValue) : number.stringValue
        } else {
            throw FeedError("Choose a JSON string, number, or boolean field.")
        }
        return Reading(value: value, detail: "JSON · \(host) · fetched", observedAt: receivedAt)
    }

    private static func validHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let isPublic = isPublicIP(name) { return isPublic }
        let labels = name.split(separator: ".")
        return labels.count > 1 && labels.last != "localhost" && labels.last != "local"
    }

    private static func publicAddressesOnly(_ host: String) async -> Bool {
        // The system resolver is synchronous. Keep slow lookups off the cooperative thread pool.
        let (results, continuation) = AsyncStream<Bool>.makeStream()
        DispatchQueue.global(qos: .utility).async {
            continuation.yield(resolvePublicHost(host))
            continuation.finish()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { continuation.finish() }
        for await result in results { return result }
        return false
    }

    private static func resolvePublicHost(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let isPublic = isPublicIP(name) { return isPublic }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &first) == 0, let first else { return false }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
                              NI_NUMERICHOST) == 0, isPublicIP(String(cString: buffer)) == true else { return false }
            current = info.ai_next
        }
        return true
    }

    private static func isPublicIP(_ host: String) -> Bool? {
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            return withUnsafeBytes(of: &v4.s_addr) { bytes in
                switch (bytes[0], bytes[1], bytes[2]) {
                case (0, _, _), (10, _, _), (127, _, _), (224..., _, _), (100, 64...127, _),
                     (169, 254, _), (172, 16...31, _), (192, 168, _), (198, 18...19, _),
                     (192, 0, 0), (192, 0, 2), (192, 88, 99), (198, 51, 100), (203, 0, 113):
                    return false
                default: return true
                }
            }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            // Accept global unicast only. This also excludes mapped IPv4 and link-local addresses.
            return withUnsafeBytes(of: &v6) { bytes in
                bytes[0] & 0xe0 == 0x20 && !bytes.starts(with: [0x20, 0x01, 0x0d, 0xb8])
                    && !bytes.starts(with: [0x20, 0x02]) && !bytes.starts(with: [0x20, 0x01, 0, 0])
            }
        }
        return nil
    }
}
