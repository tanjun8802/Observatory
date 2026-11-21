import Foundation
import SQLite3

enum CodexUsageFeed {
    static func matches(_ monitor: Monitor) -> Bool {
        guard monitor.kind == .codex else { return false }
        guard let prompt = monitor.prompt else { return false }
        let task = prompt.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let savedTask = "read the latest available codex token usage and display the total tokens used, with the reporting scope and period. refresh the displayed count whenever the usage changes if change notifications are available. otherwise, show the latest count at each refresh. if usage data is unavailable, say so."
        if task == savedTask { return true }
        let title = monitor.title.lowercased().split(whereSeparator: \.isWhitespace)
        return title == ["codex", "token", "usage"] && ["show total usage.", "show total usage"].contains(task)
    }

    static func fetch(_ monitor: Monitor) async throws -> Reading {
        let environment = ProcessInfo.processInfo.environment
        let directory = [environment["CODEX_SQLITE_HOME"], environment["CODEX_HOME"]]
            .compactMap { $0 }.first { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return try await fetch(monitor, in: directory)
    }

    static func fetch(_ monitor: Monitor, in directory: URL) async throws -> Reading {
        guard matches(monitor) else { throw UsageError.wrongFeed }
        try Task.checkCancellation()
        let file = try currentIndex(in: directory)
        var database: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard status == SQLITE_OK else { throw UsageError.unreadable }
        sqlite3_busy_timeout(database, 1000)

        // Read only the cumulative counter and its identity. Keep IDs inside SQLite.
        // Missing counters default to zero in some versions of the thread index.
        let sql = """
            SELECT SUM(counter), COUNT(counter), COUNT(*)
            FROM (
                SELECT MAX(CASE WHEN typeof(tokens_used) = 'integer' AND tokens_used > 0
                                THEN tokens_used END) AS counter
                FROM threads
                WHERE typeof(id) = 'text' AND length(trim(id)) > 0
                GROUP BY id
            )
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageError.unreadable
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw UsageError.unreadable }
        try Task.checkCancellation()
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw UsageError.noCounters }
        let tokens = sqlite3_column_int64(statement, 0)
        let reporting = sqlite3_column_int64(statement, 1)
        let indexed = sqlite3_column_int64(statement, 2)
        let detail = "\(reporting.formatted()) of \(indexed.formatted()) indexed threads have positive counters."
        let value = "\(tokens.formatted()) tokens recorded over the lifetime of the retained local Codex thread index. \(detail) "
            + "This includes retained archived threads with counters. Deleted threads, other devices and "
            + "account-wide billing are outside this reading’s coverage."

        var presentation = FeedPresentation(kind: .summary, sourceName: "Local Codex thread index")
        if let exact = Double(exactly: tokens) {
            presentation.kind = .metrics
            presentation.metrics = [FeedMetric(label: "Recorded local usage", value: exact, unit: "tokens")]
        }
        return Reading(value: value, detail: detail, observedAt: .now, presentation: presentation)
    }

    // Migrations can leave older index versions alongside the active one.
    private static func currentIndex(in directory: URL) throws -> URL {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw UsageError.unreadable
        }
        var newest: (version: Int, file: URL)?
        for file in files where file.pathExtension == "sqlite" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("state_"), let version = Int(name.dropFirst("state_".count)),
                  name == "state_\(version)", version >= 0 else { continue }
            if version > (newest?.version ?? -1) { newest = (version, file) }
        }
        guard let newest else { throw UsageError.noIndex }
        return newest.file
    }

    private enum UsageError: LocalizedError {
        case wrongFeed, noIndex, unreadable, noCounters

        var errorDescription: String? {
            switch self {
            case .wrongFeed: return "Choose the Codex Token Usage feed to read recorded local usage."
            case .noIndex: return "No local Codex thread index was found in the selected Codex home."
            case .unreadable: return "The local Codex thread counters could not be read. Check access and index compatibility."
            case .noCounters: return "The local Codex thread index contains no positive recorded token counters yet."
            }
        }
    }
}
