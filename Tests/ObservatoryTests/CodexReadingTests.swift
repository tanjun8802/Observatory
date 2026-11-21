import Foundation
import Testing
@testable import Observatory

struct CodexReadingTests {
    private func response(_ changes: [String: Any] = [:], searched: Bool = true) throws -> CodexClient.Result {
        let base: [String: Any] = [
            "status": "complete", "kind": "weather", "liveFacts": true,
            "answer": "London is cloudy at 51.8°F.\nHumidity is 74%.",
            "location": "London", "condition": "Cloudy", "weatherSymbol": "cloud.fill",
            "metrics": [["label": "Temperature", "value": 51.8, "unit": "°F"],
                        ["label": "Humidity", "value": 74, "unit": "%"],
                        ["label": "Wind", "value": 7.5, "unit": "mph"]],
            "sourceName": "Weather station", "sourceURL": "https://station.example/london",
            "evidence": "12:00 UTC station observation: 11°C, humidity 74%, wind 7.5 mph."
        ]
        let data = try JSONSerialization.data(withJSONObject: base.merging(changes) { _, new in new })
        return .init(text: String(decoding: data, as: UTF8.self), searchedWeb: searched)
    }

    @Test func weatherKeepsTextSourceAndOriginalUnits() throws {
        let reading = try CodexReading.reading(from: response(), scheduled: false, prompt: "London in Fahrenheit")
        let card = try #require(reading.presentation)
        #expect(reading.value == "London is cloudy at 51.8°F.\nHumidity is 74%.")
        #expect(card.kind == .weather && card.location == "London" && card.condition == "Cloudy")
        #expect(card.metrics.map(\.unit) == ["°F", "%", "mph"])
        #expect(card.metrics.map(\.value) == [51.8, 74, 7.5])
        #expect(card.weatherSymbol == "cloud.fill")
        #expect(card.sourceName == "Weather station" && card.sourceURL?.absoluteString == "https://station.example/london")
        #expect(try JSONDecoder().decode(Reading.self, from: JSONEncoder().encode(reading)) == reading)
    }

    @Test func weatherRejectsWrongUnitsAndInvalidMeasurements() throws {
        let reply = try response()
        #expect(throws: CodexError.self) { try CodexReading.reading(from: reply, scheduled: true, prompt: "In °C please") }
        for change: [String: Any] in [
            ["location": NSNull()], ["condition": ""], ["metrics": []],
            ["metrics": [["label": "Humidity", "value": 42, "unit": "%"]]]
        ] {
            let invalid = try response(change)
            #expect(throws: CodexError.self) { try CodexReading.reading(from: invalid, scheduled: true, prompt: "Weather") }
        }
        let unknownIcon = try response(["weatherSymbol": "trash.fill"])
        let reading = try CodexReading.reading(from: unknownIcon, scheduled: true, prompt: "Weather")
        #expect(reading.presentation?.kind == .weather && reading.presentation?.weatherSymbol == nil)
    }

    @Test func currentMeasurementsRequireSearchAndCitableEvidence() throws {
        let metrics: [String: Any] = ["kind": "metrics", "metrics": [["label":"Price", "value": 0.78, "unit":"GBP"]]]
        let reading = try CodexReading.reading(from: response(metrics), scheduled: true, prompt: "Price in GBP")
        #expect(reading.presentation?.metrics == [FeedMetric(label: "Price", value: 0.78, unit: "GBP")])
        for change: [String: Any] in [["sourceName": " "], ["sourceURL": "/missing"], ["sourceURL": "file:///tmp/data"],
                                      ["sourceURL": "https://user:secret@station.example"], ["evidence": ""]] {
            for kind in ["weather", "metrics", "summary"] {
                let reply = try response(change.merging(["kind": kind]) { _, kind in kind })
                #expect(throws: CodexError.self) { try CodexReading.reading(from: reply, scheduled: true, prompt: "Latest") }
            }
        }
        let unsearched = try response(metrics, searched: false)
        #expect(throws: CodexError.self) { try CodexReading.reading(from: unsearched, scheduled: true, prompt: "Price") }
    }

    @Test func measurementsCalculatedFromSuppliedValuesKeepTheirUnits() throws {
        let reply = try response(["kind": "metrics", "liveFacts": false, "answer": "1.25 km is 1,250 m.",
                                  "sourceName": NSNull(), "sourceURL": NSNull(), "evidence": "1.25 km × 1,000 m/km",
                                  "metrics": [["label": "Distance", "value": 1250, "unit": "m"]]], searched: false)
        let reading = try CodexReading.reading(from: reply, scheduled: false, prompt: "Express 1.25 km in m")
        #expect(reading.presentation?.metrics == [FeedMetric(label: "Distance", value: 1250, unit: "m")])
        #expect(reading.value == "1.25 km is 1,250 m.")
    }

    @Test func qualitativeAnswersAndInconclusiveQueriesPreserveText() throws {
        let summary = try response(["kind": "summary", "liveFacts": false, "answer": "First paragraph.\n\nSecond paragraph.",
                                    "metrics": [], "evidence": NSNull(), "sourceURL": NSNull(), "sourceName": NSNull()], searched: false)
        let reading = try CodexReading.reading(from: summary, scheduled: true, prompt: "Explain tides")
        #expect(reading.value == "First paragraph.\n\nSecond paragraph.")
        #expect(reading.presentation == FeedPresentation(kind: .summary))
        let incomplete = try response(["status": "inconclusive", "answer": "The station has not published a reading."])
        #expect(throws: CodexError.self) { try CodexReading.reading(from: incomplete, scheduled: true, prompt: "Weather") }
        let query = try CodexReading.reading(from: incomplete, scheduled: false, prompt: "Weather")
        #expect(query.value == "The station has not published a reading." && query.presentation == nil)
    }

    @Test func legacyReadingsStillDecodeAndEncodeWithoutPresentation() throws {
        let original = Data(#"{"value":"42","detail":"Codex","observedAt":0}"#.utf8)
        let reading = try JSONDecoder().decode(Reading.self, from: original)
        #expect(reading == Reading(value: "42", detail: "Codex", observedAt: Date(timeIntervalSinceReferenceDate: 0)))
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reading)) as? [String: Any])
        #expect(Set(fields.keys) == ["value", "detail", "observedAt"])
        let existing = Data(#"{"kind":"weather","weatherSymbol":"trash","metrics":[]}"#.utf8)
        #expect(try JSONDecoder().decode(FeedPresentation.self, from: existing).weatherSymbol == nil)
    }

    @Test func oneCLIInvocationCombinesSchemaAndLiveSearchForEachMode() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "observatory-reading-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appending(path: "codex-fixture")
        let data = try response()
        try data.text.write(to: dir.appending(path: "reply"), atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        set -eu
        parent=$(dirname "$0")
        printf 'call\\n' >> "$parent/calls"
        printf '%s\\n' "$@" > "$parent/arguments"
        cat > "$parent/input"
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output-schema) cp "$2" "$parent/schema"; shift ;;
            -o) cp "$parent/reply" "$2"; shift ;;
          esac
          shift
        done
        printf '%s\\n' '{"type":"item.completed","item":{"type":"web_search","query":"London weather"}}'
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        for scheduled in [true, false] {
            let result = try await CodexReading.read(prompt: "London in Fahrenheit", scheduled: scheduled,
                                                    client: .init(executable: cli))
            #expect(result.presentation?.kind == .weather)
            let args = try String(contentsOf: dir.appending(path: "arguments"), encoding: .utf8).components(separatedBy: "\n")
            #expect(args.contains("--output-schema") && args.contains("--json") && args.contains("web_search=\"live\""))
            let schema = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "schema"))) as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(Set(schema["required"] as? [String] ?? []) == Set(properties.keys))
            let input = try String(contentsOf: dir.appending(path: "input"), encoding: .utf8)
            #expect(input.contains("London in Fahrenheit"))
        }
        #expect(try String(contentsOf: dir.appending(path: "calls"), encoding: .utf8) == "call\ncall\n")
    }
}
