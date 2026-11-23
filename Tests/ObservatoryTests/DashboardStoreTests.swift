import Foundation
import Testing
@testable import Observatory

@Suite @MainActor
struct DashboardStoreTests {
    private let monitor = Monitor(kind: .json, title: "Test feed", endpoint: "https://example.com", field: "count")
    private let first = Reading(value: "25", detail: "Test", observedAt: Date(timeIntervalSince1970: 1700000000))

    private func boardFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/board.json")
    }

    private func waitForRefresh(_ store: DashboardStore) async throws {
        try await waitUntil { store.refreshing.isEmpty }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func feedThemePersistsIndependentlyAndCanReturnToDashboardTheme() throws {
        let file = boardFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = DashboardStore(file: file)
        let other = Monitor(kind: .codex, title: "Daily notes", prompt: "Recent events")
        store.add(monitor, initialReading: first)
        store.add(other, initialReading: first)
        let layout = store.layout
        store.setTheme(.paper, for: monitor.id)
        store.setTheme(.midnight, for: other.id)
        var earlierDraft = other
        earlierDraft.title = "Evening notes"
        store.update(earlierDraft)
        let restored = DashboardStore(file: file)
        #expect(restored.monitors.map(\.theme) == [.paper, .midnight])
        restored.setTheme(nil, for: monitor.id)
        let reopened = DashboardStore(file: file)
        #expect(reopened.monitors.map(\.theme) == [nil, .midnight])
        #expect(reopened.readings == store.readings)
        #expect(reopened.layout == layout)
        #expect(reopened.refreshing.isEmpty)
    }

    @Test func offlineRefreshRetainsLastReadingAcrossLaunches() async throws {
        let file = boardFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let online = DashboardStore(file: file) { _ in first }
        online.add(monitor)
        try await waitForRefresh(online)
        let offline = DashboardStore(file: file) { _ in throw URLError(.notConnectedToInternet) }
        offline.refreshAll()
        try await waitForRefresh(offline)
        let restored = DashboardStore(file: file) { _ in first }
        #expect(restored.monitors == [monitor])
        #expect(restored.readings[monitor.id] == first)
        #expect(restored.errors[monitor.id] != nil)
        #expect(restored.lastChecked[monitor.id] != nil)
        restored.remove(monitor)
        let empty = DashboardStore(file: file) { _ in first }
        #expect(empty.monitors.isEmpty && empty.readings.isEmpty && empty.errors.isEmpty)
    }

    @Test func wakeStartsOneNewRequestAndSupersedesSleepingRequest() async throws {
        let file = boardFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var requests = 0
        var pending: CheckedContinuation<Reading, Never>?
        let store = DashboardStore(file: file) { _ in
            requests += 1
            if requests == 1 {
                return await withCheckedContinuation { pending = $0 }
            }
            return first
        }
        store.add(monitor)
        try await waitUntil { pending != nil }
        store.suspendRequests()
        store.refreshAll()
        store.refreshAll()
        pending?.resume(returning: Reading(value: "obsolete", detail: "", observedAt: .now))
        try await waitForRefresh(store)
        #expect(requests == 2)
        #expect(store.readings[monitor.id] == first)
        store.refreshDue()
        #expect(store.refreshing.isEmpty)
        store.refreshDue(now: Date.now.addingTimeInterval(310))
        try await waitForRefresh(store)
        #expect(requests == 3)
    }

    @Test func trackedAnswerSurvivesPauseRelaunchAndFailedManualRun() async throws {
        let file = boardFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let feed = Monitor(kind: .codex, title: "Brief", prompt: "Latest?", schedule: .interval(minutes: 10))
        var requests = 0
        let fetch: (Monitor) async throws -> Reading = { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
        let original = DashboardStore(file: file, fetch: fetch)
        original.add(feed, initialReading: first)
        original.refreshOnWakeOrLaunch()
        #expect(original.refreshing.isEmpty)
        original.setPaused(true, for: feed)
        let restored = DashboardStore(file: file, fetch: fetch)
        let paused = try #require(restored.monitors.first)
        #expect(paused.isPaused)
        #expect(restored.lastChecked[feed.id] == first.observedAt)
        #expect(restored.nextRefresh(for: paused) == nil)
        restored.refresh(paused)
        try await waitForRefresh(restored)
        #expect(requests == 1)
        #expect(restored.errors[feed.id] != nil)
        #expect(restored.readings[feed.id] == first)
        #expect(restored.lastChecked[feed.id] != first.observedAt)
        restored.refreshDue(now: .distantFuture)
        restored.refreshOnWakeOrLaunch()
        restored.retryAfterReconnect()
        restored.refreshAll()
        #expect(restored.refreshing.isEmpty)
        restored.setPaused(false, for: feed)
        let resumed = DashboardStore(file: file, fetch: fetch)
        let active = try #require(resumed.monitors.first)
        #expect(!active.isPaused)
        let due = try #require(resumed.nextRefresh(for: active))
        resumed.refreshDue(now: due.addingTimeInterval(-1))
        #expect(resumed.refreshing.isEmpty)
        resumed.refreshDue(now: due)
        try await waitForRefresh(resumed)
        #expect(requests == 2)
    }

    @Test func editPreservesAnswerAndDiscardsInflightPrompt() async throws {
        let file = boardFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let feed = Monitor(kind: .codex, title: "Brief", prompt: "Original", schedule: .manual,
                           createdAt: first.observedAt)
        var pending: CheckedContinuation<Reading, Never>?
        var oldFetchReturned = false
        let latest = Reading(value: "Updated", detail: "Codex", observedAt: .now)
        let store = DashboardStore(file: file) { current in
            if current.prompt == "Original" {
                let answer = await withCheckedContinuation { pending = $0 }
                oldFetchReturned = true
                return answer
            }
            return latest
        }
        store.add(feed, initialReading: first)
        store.refresh(feed)
        try await waitUntil { pending != nil }
        var edit = feed
        edit.title = "Edited brief"
        edit.prompt = "New prompt"
        edit.schedule = .interval(minutes: 30)
        let beforeEdit = Date.now
        store.update(edit)
        #expect(store.refreshing.isEmpty)
        let saved = DashboardStore(file: file) { _ in latest }
        let edited = try #require(saved.monitors.first)
        #expect(saved.monitors.count == 1 && edited.id == feed.id)
        #expect(edited.title == edit.title && edited.prompt == edit.prompt && edited.schedule == edit.schedule)
        #expect(edited.createdAt == feed.createdAt)
        #expect(saved.readings[feed.id] == first)
        #expect(saved.lastChecked[feed.id] == first.observedAt)
        let due = try #require(saved.nextRefresh(for: edited))
        #expect(due >= beforeEdit.addingTimeInterval(1800) && due <= Date.now.addingTimeInterval(1800))
        var rename = edited
        rename.title = "Renamed"
        store.update(rename)
        #expect(store.monitors.first.flatMap { store.nextRefresh(for: $0) } == due)

        // A queued UI action can still hold the monitor from before the edit.
        store.refresh(feed)
        try await waitForRefresh(store)
        #expect(store.readings[feed.id] == latest)
        pending?.resume(returning: first)
        try await waitUntil { oldFetchReturned }
        #expect(store.readings[feed.id] == latest)
        #expect(store.errors[feed.id] == nil)
    }

    @Test func editOfPausedFeedPreservesPendingOneTimeRun() async throws {
        let file = boardFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let feed = Monitor(kind: .codex, title: "Brief", prompt: "Latest?", schedule: .manual)
        var requests = 0
        let store = DashboardStore(file: file) { _ in
            requests += 1
            return first
        }
        store.add(feed, initialReading: first)
        store.setPaused(true, for: feed)
        let due = Date.now.addingTimeInterval(3600)
        var edit = feed
        edit.schedule = .once(due)
        store.update(edit)
        store.refreshDue(now: due)
        #expect(store.refreshing.isEmpty)
        store.setPaused(false, for: feed)
        let current = try #require(store.monitors.first)
        #expect(store.nextRefresh(for: current) == due)
        store.refreshDue(now: due)
        try await waitForRefresh(store)
        #expect(requests == 1)
    }

    @Test func concurrentStockRefreshesShareOneKeychainReadAndRetryCanPrompt() async throws {
        var calls: [Bool] = []
        let reader = ProviderKeyReader { provider, interactive in
            #expect(provider == .finnhub)
            calls.append(interactive)
            try await Task.sleep(for: .milliseconds(10))
            if !interactive { throw CodexError("User interaction required") }
            return "fixture"
        }
        async let a = try? reader.read(.finnhub, interactive: false)
        async let b = try? reader.read(.finnhub, interactive: false)
        let failed = await [a, b]
        #expect(failed.allSatisfy { $0 == nil } && calls == [false])
        async let first = reader.read(.finnhub, interactive: true)
        async let second = reader.read(.finnhub, interactive: true)
        let retry = try await [first, second]
        #expect(retry == ["fixture", "fixture"] && calls == [false, true])
        _ = try? await reader.read(.finnhub, interactive: false)
        #expect(calls == [false, true, false])
    }

    @Test func savingFlightKeyRetriesOnlyTheMatchingScheduledFeed() async throws {
        let file = boardFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let flight = Monitor(kind: .codex, title: "Fare search",
                             prompt: "Three cheapest round-trip flights from SFO to JFK, departing 2030-02-03 and returning 2030-02-20. One adult in economy. Prices in GBP.")
        try #require(flight.credential == .serpapi)
        let other = Monitor(kind: .codex, title: "General question", prompt: "Explain how airlines set prices")
        var calls: [UUID] = []
        var connected = false
        let store = DashboardStore(file: file) { monitor in
            calls.append(monitor.id)
            if !connected {
                return try await FeedProvider.fetch(monitor, key: nil) { _ in
                    throw CodexError("Unexpected network call")
                }
            }
            return first
        }
        store.add(other, initialReading: first)
        store.add(flight)
        try await waitForRefresh(store)
        #expect(store.authenticationIssues == [flight.id])
        connected = true
        store.credentialsChanged("serpapi")
        try await waitForRefresh(store)
        #expect(calls == [flight.id, flight.id])
        #expect(store.errors.isEmpty && store.readings[flight.id] == first)
    }

    @Test func canceledKeychainReadDoesNotAskForReplacementKey() async throws {
        let file = boardFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stock = Monitor(kind: .stock, title: "Test quote", symbol: "TEST")
        let store = DashboardStore(file: file) { _ in
            throw CodexError("Couldn’t read the Finnhub API key from Keychain. User canceled the operation.")
        }
        store.add(stock, initialReading: first)
        store.refresh(stock)
        try await waitForRefresh(store)
        #expect(store.authenticationIssues.isEmpty)
        #expect(store.errors[stock.id] != nil && store.readings[stock.id] == first)
    }

    @Test func legacyAndCurrentCredentialFailuresAreScopedToProviders() async throws {
        let file = boardFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stock = Monitor(kind: .stock, title: "Quote")
        let flight = Monitor(kind: .flight, title: "Flight")
        let errors = [stock.id: "Enter a valid Finnhub API key.", flight.id: "The provider denied access (HTTP 403).",
                      monitor.id: "The provider denied access (HTTP 401)."]
        let legacyMonitors = try [stock, flight, monitor].map { item in
            var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
            fields.removeValue(forKey: "isPaused")
            return fields
        }
        let snapshot: [String: Any] = [
            "monitors": legacyMonitors, "readings": [], "lastChecked": [],
            "errors": try JSONSerialization.jsonObject(with: JSONEncoder().encode(errors))
        ]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        var flightError = "Enter a valid SerpApi API key."
        let store = DashboardStore(file: file) { current in
            if current.kind == .flight { throw CodexError(flightError) }
            return first
        }
        #expect(store.monitors == [stock, flight, monitor])
        #expect(store.authenticationIssues == [stock.id, flight.id])
        store.refreshAll()
        try await waitForRefresh(store)
        #expect(store.authenticationIssues == [flight.id])
        flightError = "The provider's request limit was reached (HTTP 429)."
        store.refresh(flight)
        try await waitForRefresh(store)
        #expect(store.authenticationIssues.isEmpty)
    }
}
