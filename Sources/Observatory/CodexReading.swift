import Foundation

enum CodexReading {
    static func fetch(prompt: String) async throws -> Reading {
        try await read(prompt: prompt, scheduled: true)
    }

    static func query(prompt: String) async throws -> Reading {
        try await read(prompt: prompt, scheduled: false)
    }

    static func read(prompt: String, scheduled: Bool, client: CodexClient = .init()) async throws -> Reading {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexError("Enter a question or a feed prompt.")
        }
        let instruction = scheduled
            ? "Give a concise dashboard update. Show verified parts of a multipart request and identify any gaps."
            : "Give the full answer to the question, including reasoning or formatting the user requested."
        let reply = try await client.run(instruction + "\n" + readingInstructions + "\nUser request: " + prompt,
                                         schema: schema, liveSearch: true)
        return try reading(from: reply, scheduled: scheduled, prompt: prompt)
    }

    // The read-only Codex process runs in an empty temporary directory. Pass the
    // shipped skill explicitly so queries and scheduled refreshes see the same guidance.
    static var readingInstructions: String {
        get throws {
            let bundle: Bundle
            if Bundle.main.bundleIdentifier == "app.observatory.dashboard" {
                guard let url = Bundle.main.url(forResource: "Observatory_Observatory", withExtension: "bundle"),
                      let packaged = Bundle(url: url) else {
                    throw CodexError("Observatory’s presentation resources are missing. Reinstall the app and retry.")
                }
                bundle = packaged
            } else {
                bundle = .module
            }
            guard let file = bundle.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/present-feed-data"),
                  let instructions = try? String(contentsOf: file, encoding: .utf8), !instructions.isEmpty else {
                throw CodexError("Observatory could not load its data presentation skill. Reinstall the app and retry.")
            }
            return instructions
        }
    }

    private struct Response: Decodable {
        enum Status: String, Decodable { case complete, partial, inconclusive }
        let status: Status
        let answer: String
        let kind: FeedPresentation.Kind
        let liveFacts: Bool
        let location: String?
        let condition: String?
        let weatherSymbol: String?
        let metrics: [FeedMetric]
        let rows: [FeedRow]?
        let sourceName: String?
        let sourceURL: String?
        let evidence: String?
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func sourceURL(_ value: String?) -> URL? {
        guard let value = nonempty(value),
              let url = URL(string: value, encodingInvalidCharacters: false),
              url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty,
              url.user() == nil, url.password() == nil else { return nil }
        return url
    }

    static func reading(from reply: CodexClient.Result, scheduled: Bool, prompt: String) throws -> Reading {
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(reply.text.utf8)),
              let answer = nonempty(response.answer) else {
            throw CodexError("Codex returned an unreadable reading. Try again.")
        }
        if response.status == .inconclusive {
            if scheduled {
                let reason = String(answer.prefix(while: { !$0.isNewline }))
                    .replacingOccurrences(of: "**", with: "")
                throw CodexError(reason.count > 220 ? String(reason.prefix(219)) + "…" : reason)
            }
            return Reading(value: answer, detail: "Codex", observedAt: .now)
        }

        let name = nonempty(response.sourceName)
        let url = sourceURL(response.sourceURL)
        if response.kind == .weather || response.liveFacts || name != nil || response.sourceURL != nil {
            guard reply.searchedWeb, name != nil, url != nil, nonempty(response.evidence) != nil else {
                throw CodexError("Codex could not verify this reading against a named web source.")
            }
        }

        var presentation = FeedPresentation(kind: response.kind, sourceName: name, sourceURL: url)
        if response.status == .partial {
            guard nonempty(response.evidence) != nil else {
                throw CodexError("Codex could not substantiate the partial reading.")
            }
            presentation.isPartial = true
        }
        let metrics = response.metrics
        guard metrics.allSatisfy({ nonempty($0.label) != nil && $0.value.isFinite }) else {
            throw CodexError("Codex returned an invalid measurement.")
        }
        switch response.kind {
        case .weather:
            guard let location = nonempty(response.location), let condition = nonempty(response.condition),
                  let temperature = metrics.first, temperature.label == "Temperature",
                  validTemperatureUnit(temperature.unit, for: prompt) else {
                throw CodexError("Codex could not verify the location, conditions, and temperature in the requested units.")
            }
            let extras = metrics.dropFirst()
            let labels = extras.map(\.label)
            guard [[], ["Humidity"], ["Wind"], ["Humidity", "Wind"]].contains(labels),
                  extras.allSatisfy({ nonempty($0.unit) != nil }) else {
                throw CodexError("Codex returned invalid weather measurements.")
            }
            presentation.location = location
            presentation.condition = condition
            presentation.weatherSymbol = response.weatherSymbol
            presentation.metrics = metrics
        case .metrics:
            guard !metrics.isEmpty, nonempty(response.evidence) != nil else {
                throw CodexError("Codex returned no supported measurements.")
            }
            presentation.metrics = metrics
        case .list:
            guard let rows = response.rows, rows.allSatisfy({ nonempty($0.title) != nil }) else {
                throw CodexError("Codex returned an incomplete list reading.")
            }
            // Omit an invalid optional link while preserving the item's verified text.
            presentation.rows = rows.map { row in
                var item = row
                item.url = row.link?.absoluteString
                return item
            }
        case .summary:
            break
        }
        return Reading(value: answer, detail: name.map { "Codex · " + $0 } ?? "Codex",
                       observedAt: .now, presentation: presentation)
    }

    private static func validTemperatureUnit(_ unit: String, for prompt: String) -> Bool {
        let units = [
            ("°C", ["°c", "celsius", "centigrade"]), ("°F", ["°f", "fahrenheit"]),
            ("K", ["kelvin"]), ("°R", ["°r", "rankine"])
        ]
        let normalized = unit.lowercased().replacingOccurrences(of: "degrees", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let actual = units.first(where: { symbol, names in
            symbol.lowercased() == normalized || symbol.lowercased().replacingOccurrences(of: "°", with: "") == normalized
                || names.contains(normalized)
        }) else { return false }
        let request = prompt.lowercased()
        let explicit = units.filter { _, spellings in spellings.contains(where: request.contains) }
        return explicit.count != 1 || explicit.first?.0 == actual.0
    }

    static let schema = """
    {
      "type":"object","additionalProperties":false,
      "required":["status","answer","kind","liveFacts","location","condition","weatherSymbol","metrics","rows","sourceName","sourceURL","evidence"],
      "properties":{
        "status":{"type":"string","enum":["complete","partial","inconclusive"]},
        "answer":{"type":"string"},
        "kind":{"type":"string","enum":["weather","metrics","summary","list"]},
        "liveFacts":{"type":"boolean"},
        "location":{"type":["string","null"]},
        "condition":{"type":["string","null"]},
        "weatherSymbol":{"type":["string","null"],"enum":[\(FeedPresentation.weatherSymbols.map { "\"\($0)\"" }.joined(separator: ",")),null]},
        "metrics":{"type":"array","items":{"type":"object","additionalProperties":false,
          "required":["label","value","unit"],"properties":{
            "label":{"type":"string"},"value":{"type":"number"},"unit":{"type":"string"}}}},
        "rows":{"type":"array","items":{"type":"object","additionalProperties":false,
          "required":["title","detail","value","url"],"properties":{
            "title":{"type":"string"},"detail":{"type":"string"},"value":{"type":"string"},"url":{"type":["string","null"]}}}},
        "sourceName":{"type":["string","null"]},
        "sourceURL":{"type":["string","null"]},
        "evidence":{"type":["string","null"]}
      }
    }
    """
}
