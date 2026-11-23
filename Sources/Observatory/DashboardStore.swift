import Combine
import Foundation
import Security

private struct ProviderKeyReadFailure: LocalizedError {
    let provider: Credential
    let cause: Error
    var errorDescription: String? {
        let error = cause as NSError
        if error.domain == NSOSStatusErrorDomain,
           [errSecInteractionNotAllowed, errSecUserCanceled, errSecAuthFailed].contains(OSStatus(error.code)) {
            return "Keychain access needed for \(provider.providerName). Choose Retry failed and allow Observatory to read the saved key."
        }
        return "Couldn’t read the \(provider.providerName) API key from Keychain. \(cause.localizedDescription)"
    }
}

private struct BoardSnapshot: Codable {
    var monitors: [Monitor] = []
    var readings: [UUID: Reading] = [:]
    var lastChecked: [UUID: Date] = [:]
    var errors: [UUID: String] = [:]
    var layout: CanvasLayout?
    var layoutVersion: Int?
}

extension MonitorKind {
    var credential: Credential? {
        switch self {
        case .flight: return .serpapi
        case .stock: return .finnhub
        case .json, .codex: return nil
        }
    }

    var refreshInterval: TimeInterval { self == .flight ? 3600 : 300 }
}

extension Monitor {
    var credential: Credential? {
        if kind == .codex, RoundTripFlightFeed.search(for: self) != nil { return .serpapi }
        return kind.credential
    }
}

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var monitors: [Monitor] = []
    @Published private(set) var readings: [UUID: Reading] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var lastChecked: [UUID: Date] = [:]
    @Published private(set) var layout = CanvasLayout()
    @Published var storageMessage: String?

    var authenticationIssues: Set<UUID> {
        Set(monitors.compactMap { monitor in
            guard monitor.credential != nil, let error = errors[monitor.id] else { return nil }
            let message = error.lowercased()
            if message.contains("api key"),
               ["enter", "missing", "invalid", "required", "add", "not configured"].contains(where: message.contains) {
                return monitor.id
            }
            switch message {
            case "the provider denied access (http 401).", "the provider denied access (http 403).",
                 "the feed returned http 401.", "the feed returned http 403.":
                return monitor.id
            default: return nil
            }
        })
    }

    private let file: URL
    private static let providerKeys = ProviderKeyReader { provider, interactive in
        try await KeyStore.shared.read(provider, interactive: interactive)
    }
    private let fetch: (Monitor, Bool) async throws -> Reading
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var preserveUnreadableFile = false

    init(file: URL = URL.applicationSupportDirectory.appending(path: "Observatory/board.json"),
         fetch: ((Monitor) async throws -> Reading)? = nil) {
        self.file = file
        if let fetch {
            self.fetch = { monitor, _ in try await fetch(monitor) }
        } else {
            self.fetch = Self.fetchReading
        }
        do {
            let snapshot = try JSONDecoder().decode(BoardSnapshot.self, from: Data(contentsOf: file))
            monitors = snapshot.monitors
            readings = snapshot.readings
            lastChecked = snapshot.lastChecked
            errors = snapshot.errors
            layout = CanvasLayout(monitors: monitors, saved: snapshot.layout, savedVersion: snapshot.layoutVersion ?? 1)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // A new board starts empty.
        } catch {
            storageMessage = "Your saved board could not be read. Observatory will preserve the original file when you save a new monitor."
            preserveUnreadableFile = true
        }
    }

    private static func fetchReading(_ monitor: Monitor, interactive: Bool) async throws -> Reading {
        var key: String?
        if let provider = monitor.credential {
            do {
                key = try await providerKeys.read(provider, interactive: interactive)
            } catch {
                throw ProviderKeyReadFailure(provider: provider, cause: error)
            }
        }
        return try await FeedProvider.fetch(monitor, key: key)
    }

    func add(_ monitor: Monitor) {
        guard !monitors.contains(where: { $0.id == monitor.id }) else { return }
        layout.insert(monitor)
        monitors.append(monitor)
        save()
        guard !monitor.isPaused else { return }
        switch monitor.schedule {
        case .once?: break
        default: refresh(monitor)
        }
    }

    func add(_ monitor: Monitor, initialReading: Reading) {
        guard !monitors.contains(where: { $0.id == monitor.id }) else { return }
        var tracked = monitor
        if tracked.schedule != nil && tracked.schedule != .manual { tracked.scheduleAnchor = .now }
        layout.insert(tracked)
        monitors.append(tracked)
        readings[monitor.id] = initialReading
        lastChecked[monitor.id] = initialReading.observedAt
        save()
    }

    func setTheme(_ theme: BoardTheme?, for id: UUID) {
        guard let index = monitors.firstIndex(where: { $0.id == id }), monitors[index].theme != theme else { return }
        monitors[index].theme = theme
        save()
    }

    func setPaused(_ paused: Bool, for monitor: Monitor) {
        guard let index = monitors.firstIndex(where: { $0.id == monitor.id }),
              monitors[index].kind == .codex, monitors[index].isPaused != paused else { return }
        if paused {
            cancelRefresh(monitor.id)
        } else {
            switch monitors[index].schedule {
            case .interval?, .daily?: monitors[index].scheduleAnchor = .now
            default: break
            }
        }
        monitors[index].isPaused = paused
        save()
    }

    func update(_ replacement: Monitor) {
        guard let index = monitors.firstIndex(where: { $0.id == replacement.id }),
              monitors[index].kind == .codex, replacement.kind == .codex else { return }
        let original = monitors[index]
        var edited = replacement
        edited.createdAt = original.createdAt
        edited.isPaused = original.isPaused
        edited.theme = original.theme
        edited.scheduleAnchor = original.schedule == edited.schedule ? original.scheduleAnchor : .now
        guard edited != original else { return }
        if original.prompt != edited.prompt || original.schedule != edited.schedule {
            cancelRefresh(edited.id)
            errors.removeValue(forKey: edited.id)
        }
        monitors[index] = edited
        save()
    }

    private func cancelRefresh(_ id: UUID) {
        jobs.removeValue(forKey: id)?.cancel()
        refreshing.remove(id)
    }

    func arrangeAsSquares() {
        layout = CanvasLayout(monitors: monitors)
        save()
    }

    func placeWidget(_ id: UUID, at placement: WidgetPlacement) {
        guard layout.placements[id] != nil, layout.set(placement, for: id) else { return }
        save()
    }

    func remove(_ monitor: Monitor) {
        layout.remove(monitor.id)
        cancelRefresh(monitor.id)
        monitors.removeAll { $0.id == monitor.id }
        readings.removeValue(forKey: monitor.id)
        lastChecked.removeValue(forKey: monitor.id)
        errors.removeValue(forKey: monitor.id)
        save()
    }

    func suspendRequests() {
        jobs.values.forEach { $0.cancel() }
        jobs.removeAll()
        refreshing.removeAll()
    }

    func credentialsChanged(_ provider: String) {
        for monitor in monitors where !monitor.isPaused && monitor.credential?.rawValue == provider {
            cancelRefresh(monitor.id)
            refresh(monitor)
        }
    }

    func retryFailed(_ candidates: [Monitor]) {
        for monitor in candidates where errors[monitor.id] != nil && !monitor.isPaused {
            refresh(monitor)
        }
    }

    func refreshAll() {
        for monitor in monitors where !monitor.isPaused { refresh(monitor) }
    }

    func refreshOnWakeOrLaunch() {
        for monitor in monitors where !monitor.isPaused && monitor.kind != .codex { refresh(monitor, interactive: false) }
        refreshDue()
    }

    func retryAfterReconnect() {
        for monitor in monitors where !monitor.isPaused && errors[monitor.id] != nil {
            if monitor.kind == .codex, monitor.schedule == .manual { continue }
            refresh(monitor, interactive: false)
        }
    }

    func nextRefresh(for monitor: Monitor) -> Date? {
        guard !monitor.isPaused else { return nil }
        var baseline = lastChecked[monitor.id]
        if let anchor = monitor.scheduleAnchor {
            baseline = max(anchor, baseline ?? anchor)
        }
        return monitor.nextRefresh(after: baseline)
    }

    func refreshDue(now: Date = .now) {
        for monitor in monitors where nextRefresh(for: monitor).map({ $0 <= now }) == true {
            refresh(monitor, interactive: false)
        }
    }

    func refresh(_ monitor: Monitor, interactive: Bool = true) {
        let id = monitor.id
        guard jobs[id] == nil, let current = monitors.first(where: { $0.id == id }) else { return }
        refreshing.insert(id)
        jobs[id] = Task {
            do {
                try Task.checkCancellation()
                let result = try await fetch(current, interactive)
                guard !Task.isCancelled else { return }
                readings[id] = result
                errors.removeValue(forKey: id)
            } catch {
                guard !Task.isCancelled else { return }
                errors[id] = error.localizedDescription
            }
            lastChecked[id] = .now
            refreshing.remove(id)
            jobs.removeValue(forKey: id)
            save()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if preserveUnreadableFile {
                let backup = file.deletingPathExtension().appendingPathExtension("recovery-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: file, to: backup)
                preserveUnreadableFile = false
            }
            let snapshot = BoardSnapshot(monitors: monitors, readings: readings, lastChecked: lastChecked, errors: errors, layout: layout, layoutVersion: CanvasLayout.version)
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        } catch {
            storageMessage = "Your board could not be saved. \(error.localizedDescription)"
        }
    }
}
