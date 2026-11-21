import Foundation
import SQLite3
import Testing
@testable import Observatory

struct CodexUsageFeedTests {
    private let feed = Monitor(kind: .codex, title: "Codex Token Usage", prompt: "Show total usage.")

    @Test func onlyMatchesTheNamedCodexFeed() {
        var monitor = feed
        monitor.title = "  CODEX   Token\nUsage "
        #expect(CodexUsageFeed.matches(monitor))
        monitor.title = "Explain Codex token usage pricing"
        #expect(!CodexUsageFeed.matches(monitor))
        monitor.title = feed.title
        monitor.kind = .json
        #expect(!CodexUsageFeed.matches(monitor))
    }

    @Test func sumsOneCumulativeCounterPerThreadAndRereadsOnRefresh() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("state_12.sqlite")
        try execute(db, """
            CREATE TABLE threads(id TEXT, tokens_used, transcript TEXT);
            INSERT INTO threads VALUES
              ('first', 70, 'PRIVATE_FIXTURE'), ('first', 100, NULL), ('first', 100, NULL),
              ('second', 100, NULL), ('zero', 0, NULL), ('invalid', -12, NULL),
              ('missing', NULL, NULL), ('text', '1234', NULL);
            """)
        try execute(directory.appendingPathComponent("state_9.sqlite"), """
            CREATE TABLE threads(id TEXT, tokens_used INTEGER);
            INSERT INTO threads VALUES ('first', 999);
            """)
        let reading = try await CodexUsageFeed.fetch(feed, in: directory)
        #expect(reading.presentation?.metrics.first?.value == 200)
        #expect(reading.value.contains("2 of 6"))
        #expect(!reading.value.contains("PRIVATE_FIXTURE"))
        #expect(!reading.value.contains(directory.path))
        try execute(db, "INSERT INTO threads VALUES ('second', 145, NULL);")
        let refreshed = try await CodexUsageFeed.fetch(feed, in: directory)
        #expect(refreshed.presentation?.metrics.first?.value == 245)
    }

    @Test func missingEmptyOrUnsupportedCountersAreUnavailable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("state_5.sqlite")
        for setup in ["", "CREATE TABLE threads(id TEXT);",
                      "ALTER TABLE threads ADD COLUMN tokens_used INTEGER;",
                      "INSERT INTO threads VALUES ('empty', 0);"] {
            if !setup.isEmpty { try execute(db, setup) }
            do {
                _ = try await CodexUsageFeed.fetch(feed, in: directory)
                Issue.record("An unavailable counter produced a reading")
            } catch {
                #expect(!error.localizedDescription.contains(directory.path))
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func execute(_ file: URL, _ sql: String) throws {
        var db: OpaquePointer?
        let status = sqlite3_open(file.path, &db)
        defer { sqlite3_close(db) }
        guard status == SQLITE_OK, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "Usage fixture", code: 1)
        }
    }
}
