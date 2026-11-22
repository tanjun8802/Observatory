import Foundation

enum FeedSchedule: Codable, Equatable {
    case manual
    case once(Date)
    case interval(minutes: Int)
    case daily(hour: Int, minute: Int)

    func next(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        switch self {
        case .once(let due): return date < due ? due : nil
        case .manual: return nil
        case .interval(let minutes): return date.addingTimeInterval(Double(minutes) * 60)
        case .daily(let hour, let minute):
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                     matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }
    }

    var label: String {
        switch self {
        case .once(let due): return due.formatted(date: .abbreviated, time: .shortened)
        case .manual: return "On demand"
        case .interval(let minutes): return "Every \(minutes) min"
        case .daily(let hour, let minute): return String(format: "Daily at %02d:%02d", hour, minute)
        }
    }
}

enum FeedCadence: String, Codable {
    case manual, interval, daily, once
}

struct FeedProposal: Decodable {
    var title: String
    var prompt: String
    var cadence: FeedCadence
    var runAt: String
    var minutes: Int
    var hour: Int
    var minute: Int
    private var original: Monitor?

    private enum CodingKeys: String, CodingKey {
        case title, prompt, cadence, runAt, minutes, hour, minute
    }

    init(title: String, prompt: String, cadence: FeedCadence, runAt: String, minutes: Int, hour: Int, minute: Int) {
        self.title = title
        self.prompt = prompt
        self.cadence = cadence
        self.runAt = runAt
        self.minutes = minutes
        self.hour = hour
        self.minute = minute
    }

    init(tracking question: String) {
        let summary = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let title = summary.count > 60 ? String(summary.prefix(59)) + "…" : summary
        self.init(title: title, prompt: question, cadence: .manual, runAt: "", minutes: 60, hour: 9, minute: 0)
    }

    init(editing monitor: Monitor) {
        self.init(title: monitor.title, prompt: monitor.prompt ?? "", cadence: .manual,
                  runAt: "", minutes: 60, hour: 9, minute: 0)
        original = monitor
        switch monitor.schedule ?? .manual {
        case .manual: break
        case .once(let due):
            cadence = .once
            runAt = ISO8601DateFormatter().string(from: due)
        case .interval(let minutes):
            cadence = .interval
            self.minutes = minutes
        case .daily(let hour, let minute):
            cadence = .daily
            self.hour = hour
            self.minute = minute
        }
    }

    func monitor(now: Date = .now) throws -> Monitor {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !task.isEmpty else { throw CodexError("Enter a feed name and a prompt.") }
        let schedule: FeedSchedule?
        switch cadence {
        case .once:
            let formatter = ISO8601DateFormatter()
            if case .once(let due) = original?.schedule, formatter.string(from: due) == runAt {
                schedule = .once(due)
            } else if let due = formatter.date(from: runAt), due > now {
                schedule = .once(due)
            } else {
                throw CodexError("Choose a future date and time for the feed.")
            }
        case .manual:
            // Older on-demand monitors have no stored schedule.
            schedule = original != nil && original?.schedule == nil ? nil : .manual
        case .interval where (1...10080).contains(minutes): schedule = .interval(minutes: minutes)
        case .daily where (0..<24).contains(hour) && (0..<60).contains(minute):
            schedule = .daily(hour: hour, minute: minute)
        default: throw CodexError("Choose a daily time or an interval of 1 to 10,080 minutes.")
        }
        var monitor = original ?? Monitor(kind: .codex, title: name, createdAt: now)
        monitor.title = name
        monitor.prompt = prompt
        monitor.schedule = schedule
        return monitor
    }

    static let schema = """
        {"type":"object","additionalProperties":false,"required":["title","prompt","cadence","runAt","minutes","hour","minute"],
         "properties":{"title":{"type":"string"},"prompt":{"type":"string"},
         "cadence":{"type":"string","enum":["manual","interval","daily","once"]},"runAt":{"type":"string"},"minutes":{"type":"integer"},
         "hour":{"type":"integer"},"minute":{"type":"integer"}}}
        """

    static var draftingInstructions: String {
        """
            Draft a read-only dashboard feed for the following request. Return a short title and a self-contained
            prompt to run at each refresh. Preserve every requested field, source, unit and presentation preference in the recurring prompt. Extract a local daily time
            or a repeat interval in whole minutes. For a one-time scheduled request choose once and set runAt to an ISO 8601
            timestamp with seconds and UTC offset. Otherwise use an empty runAt. Use manual if no timing is specified.
            The current instant is \(ISO8601DateFormatter().string(from: .now)).
            Use zero for unused numeric fields. Local time zone: \(TimeZone.current.identifier).
            For weather feeds keep the requested location, current/forecast distinction and temperature units
            explicit in the recurring prompt. When no schedule is requested, choose manual.
        """
    }

    static func suggest(_ request: String, client: CodexClient = .init()) async throws -> Self {
        let response = try await client.answer(draftingInstructions + "\nRequest: " + request, schema: schema)
        guard let draft = try? JSONDecoder().decode(Self.self, from: Data(response.utf8)) else {
            throw CodexError("Codex returned an unreadable feed draft. Try describing the feed again.")
        }
        _ = try draft.monitor()
        return draft
    }
}

extension Monitor {
    func nextRefresh(after checked: Date?) -> Date? {
        if let schedule {
            if checked == nil, case .interval = schedule { return .distantPast }
            return schedule.next(after: checked ?? createdAt ?? .now)
        }
        if kind == .codex { return nil }
        return (checked ?? .distantPast).addingTimeInterval(kind.refreshInterval)
    }
}
