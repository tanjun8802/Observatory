import Accessibility
import Darwin
import Foundation
import SwiftUI

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasControlCharacters: Bool { rangeOfCharacter(from: .controlCharacters) != nil }
}

enum FeedInput: Hashable {
    case title, symbol, origin, destination, flightNumber, departure, currency, endpoint, field
    case request, prompt, interval, runAt, dailyTime
}

struct FormIssue: Error {
    let input: FeedInput
    let message: String

    init(_ input: FeedInput, _ message: String) {
        self.input = input
        self.message = message
    }
}

struct FeedFormFocus: DynamicProperty {
    @FocusState var keyboard: FeedInput?
    @AccessibilityFocusState var accessibility: FeedInput?
    @State var issue: FormIssue?

    func report(_ problem: FormIssue) {
        issue = problem
        keyboard = problem.input
        accessibility = problem.input
        AccessibilityNotification.Announcement(problem.message).post()
    }
}

extension View {
    func feedInput<Value: Equatable>(_ input: FeedInput, value: Value, focus: FeedFormFocus) -> some View {
        let issue = focus.issue
        return self.focused(focus.$keyboard, equals: input)
            .accessibilityFocused(focus.$accessibility, equals: input)
            .accessibilityHint(issue.flatMap { $0.input == input ? $0.message : nil } ?? "")
            .onChange(of: value) {
                if focus.issue?.input == input { focus.issue = nil }
            }
    }
}

private struct MonitorDraft {
    var kind = MonitorKind.stock {
        didSet {
            if kind != oldValue && hasSampleTitle { title = "" }
        }
    }
    var title = "" {
        didSet { hasSampleTitle = false }
    }
    private var hasSampleTitle = false
    var symbol = ""
    var origin = ""
    var destination = ""
    var flightNumber = ""
    var departure = Date.now
    var currency = "USD"
    var endpoint = ""
    var field = ""

    mutating func useEarthquakeSample() {
        endpoint = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/significant_month.geojson"
        field = "metadata.count"
        if title.isEmpty {
            title = "Significant earthquakes in the past month"
            hasSampleTitle = true
        }
    }

    func monitor(today: Date = .now) throws -> Monitor {
        guard !title.trimmed.hasControlCharacters else {
            throw FormIssue(.title, "Use a single line for the monitor name.")
        }
        var monitor = Monitor(kind: kind, title: title.trimmed)
        switch kind {
        case .codex: throw FormIssue(.title, "Describe your task in the Codex feed editor.")
        case .stock:
            let ticker = symbol.trimmed
            guard ticker.range(of: #"^\^?[A-Za-z0-9]+([.:-][A-Za-z0-9]+)*$"#,
                               options: .regularExpression) != nil,
                  ticker.utf8.count <= 32, !ticker.hasControlCharacters else {
                throw FormIssue(.symbol, "Enter a ticker symbol, such as AAPL or BRK.B.")
            }
            monitor.symbol = ticker.uppercased()
            if monitor.title.isEmpty { monitor.title = monitor.symbol }
        case .flight:
            monitor.origin = try airport(origin, input: .origin)
            monitor.destination = try airport(destination, input: .destination)
            guard monitor.destination != monitor.origin else {
                throw FormIssue(.destination, "Choose a different arrival airport.")
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            guard calendar.startOfDay(for: departure) >= calendar.startOfDay(for: today) else {
                throw FormIssue(.departure, "Choose today or a future departure date.")
            }
            let date = calendar.dateComponents([.year, .month, .day], from: departure)
            guard let year = date.year, (1...9999).contains(year),
                  let month = date.month, let day = date.day else {
                throw FormIssue(.departure, "Choose a valid departure date.")
            }
            monitor.departure = String(format: "%04d-%02d-%02d", year, month, day)
            let code = currency.trimmed
            guard isThreeLetters(code), FlightCurrency.supported.contains(code.uppercased()) else {
                throw FormIssue(.currency, "Choose a supported Google Flights currency, such as GBP, USD or EUR.")
            }
            monitor.currency = code.uppercased()
            let number = flightNumber.trimmed.uppercased().replacingOccurrences(of: " ", with: "")
            if !number.isEmpty {
                guard number.range(of: #"^[A-Z0-9]{2}[0-9]{1,4}$"#, options: .regularExpression) != nil else {
                    throw FormIssue(.flightNumber, "Enter an airline code and flight number, such as BA117.")
                }
                monitor.flightNumber = number
                if monitor.title.isEmpty { monitor.title = number }
            }
            if monitor.title.isEmpty { monitor.title = "\(monitor.origin) → \(monitor.destination)" }
        case .json:
            let address = endpoint.trimmed
            guard let url = URLComponents(string: address, encodingInvalidCharacters: false),
                  url.scheme?.lowercased() == "https",
                  let host = url.host, Self.isPublicHost(host),
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.rangeOfPort == nil || (1...65535).contains(url.port ?? 0),
                  url.url != nil else {
                throw FormIssue(.endpoint, "Enter a public HTTPS URL without sign-in details or a fragment.")
            }
            let path = field.trimmed
            let parts = path.components(separatedBy: ".")
            guard !path.hasControlCharacters,
                  parts.allSatisfy({ !$0.isEmpty && $0 == $0.trimmed }) else {
                throw FormIssue(.field, "Enter a field path with a name between each dot, such as data.value.")
            }
            monitor.endpoint = address
            monitor.field = path
            if monitor.title.isEmpty { monitor.title = "\(host) · \(path)" }
        }
        return monitor
    }

    private func isThreeLetters(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
    }

    private func airport(_ value: String, input: FeedInput) throws -> String {
        let code = value.trimmed
        guard isThreeLetters(code) else {
            throw FormIssue(input, "Enter a three-letter airport code, such as LHR.")
        }
        return code.uppercased()
    }

    // Screen literal addresses and local names without contacting the endpoint during entry.
    private static func isPublicHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") {
            let literal = String(host.dropFirst().dropLast())
            var address = in6_addr()
            guard inet_pton(AF_INET6, literal, &address) == 1 else { return false }
            return withUnsafeBytes(of: &address) { bytes in
                bytes[0] & 0xe0 == 0x20 && !bytes.starts(with: [0x20, 0x01, 0x0d, 0xb8])
                    && !bytes.starts(with: [0x20, 0x02]) && !bytes.starts(with: [0x20, 0x01, 0, 0])
            }
        }
        var address = in_addr()
        if inet_aton(host, &address) == 1 {
            return withUnsafeBytes(of: &address.s_addr) { bytes in
                switch (bytes[0], bytes[1], bytes[2]) {
                case (0, _, _), (10, _, _), (127, _, _), (224..., _, _),
                     (100, 64...127, _), (169, 254, _), (172, 16...31, _),
                     (192, 168, _), (192, 0, 0), (192, 0, 2), (192, 88, 99),
                     (198, 18...19, _), (198, 51, 100), (203, 0, 113):
                    return false
                default:
                    return true
                }
            }
        }
        let labels = host.components(separatedBy: ".")
        guard host.utf8.count <= 253, labels.count >= 2, let suffix = labels.last,
              suffix.range(of: #"[a-z]"#, options: .regularExpression) != nil,
              !["localhost", "local", "internal", "lan", "test", "invalid", "example", "onion"].contains(suffix),
              host != "home.arpa", !host.hasSuffix(".home.arpa") else { return false }
        return labels.allSatisfy {
            $0.utf8.count <= 63 && $0.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"#,
                                            options: .regularExpression) != nil
        }
    }
}

private struct FormHeader: View {
    @Environment(\.boardPalette) private var ink
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(ink.accent)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 23, weight: .medium, design: .serif))
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InputLabel<Content: View>: View {
    let name: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FormSurface: ViewModifier {
    @Environment(\.boardPalette) private var ink
    func body(content: Content) -> some View {
        content
            .padding(22)
            .frame(minWidth: 380, idealWidth: 436, maxWidth: .infinity, alignment: .leading)
            .background(ink.background)
            .tint(ink.accent)
            .textFieldStyle(.roundedBorder)
    }
}

struct FormErrorText: View {
    @Environment(\.boardPalette) private var ink
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(ink.coral)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ScheduledFeedSheet: View {
    @State private var form: CodexFeedForm
    let editing: Bool
    let onSave: (Monitor) -> Void

    let heading: String

    init(draft: FeedProposal, editing: Bool, heading: String? = nil, onSave: @escaping (Monitor) -> Void) {
        _form = State(initialValue: CodexFeedForm(proposal: draft))
        self.editing = editing
        self.heading = heading ?? (editing ? "Edit feed" : "Track this answer")
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormHeader(title: heading, icon: "calendar.badge.clock")
            CodexFeedEditor(form: $form, editing: editing, onSave: onSave)
        }
        .modifier(FormSurface())
    }
}

private struct ProviderConnection: View {
    let provider: Credential
    @State private var status: String?
    @State private var showSettings = false

    var body: some View {
        HStack {
            Text(status ?? "Checking provider key…").foregroundStyle(.secondary)
            Spacer()
            Button("Configure…") { showSettings = true }
                .accessibilityLabel("Configure \(provider.providerName)")
        }
        .font(.callout)
        .task(id: provider) { await check() }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await check() } }) {
            ProviderSettingsView(provider: provider)
        }
    }

    private func check() async {
        do {
            status = try await KeyStore.shared.hasKey(provider)
                ? "\(provider.providerName) key saved" : "\(provider.providerName) key needed for readings"
        } catch {
            status = "Couldn’t check the \(provider.providerName) key."
        }
    }
}

struct AddMonitorView: View {
    var onSave: (Monitor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var useCodex = true
    @State private var draft = MonitorDraft()
    @State private var codexForm = CodexFeedForm()
    private var focus = FeedFormFocus()

    init(onSave: @escaping (Monitor) -> Void) {
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormHeader(title: "Add feed", icon: "waveform.path.ecg")
            Picker("Feed setup", selection: $useCodex) {
                Text("Describe with Codex").tag(true)
                Text("Data provider").tag(false)
            }.pickerStyle(.segmented)
            if useCodex {
                CodexFeedEditor(form: $codexForm, canReturnToRequest: true, onSave: onSave)
            } else {
                providerFields
            }
        }
        .modifier(FormSurface())
    }

    private var providerFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Monitor type", selection: $draft.kind) {
                Text("Stock").tag(MonitorKind.stock)
                Text("One-way flight").tag(MonitorKind.flight)
                Text("JSON field").tag(MonitorKind.json)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("Monitor type")

            switch draft.kind {
            case .codex: EmptyView()
            case .stock:
                input("Ticker symbol", "e.g. AAPL", $draft.symbol, .symbol)
            case .flight:
                HStack(spacing: 12) {
                    input("From airport", "IATA code", $draft.origin, .origin)
                    input("To airport", "IATA code", $draft.destination, .destination)
                }
                HStack(alignment: .top, spacing: 12) {
                    InputLabel(name: "Departure date") {
                        DatePicker("Departure date", selection: $draft.departure,
                                   in: Calendar.current.startOfDay(for: .now)...,
                                   displayedComponents: .date)
                            .labelsHidden()
                            .feedInput(.departure, value: draft.departure, focus: focus)
                    }
                    input("Currency", "ISO code", $draft.currency, .currency)
                }
                input("Nonstop flight number", "Optional, e.g. BA117", $draft.flightNumber, .flightNumber)
                Text("Each refresh requests a new fare search from SerpApi and uses your search quota.")
                    .font(.caption).foregroundStyle(.secondary)
            case .json:
                input("Public HTTPS URL", "https://…", $draft.endpoint, .endpoint)
                input("JSON field path", "e.g. data.value", $draft.field, .field)
                if draft.endpoint.isEmpty && draft.field.isEmpty {
                    Button("Try the USGS earthquake feed") {
                        draft.useEarthquakeSample()
                        focus.issue = nil
                        focus.keyboard = .title
                    }
                    .buttonStyle(.link)
                }
            }
            if let provider = draft.kind.credential {
                ProviderConnection(provider: provider)
            }
            input("Feed name", "Optional", $draft.title, .title)

            if let issue = focus.issue { FormErrorText(message: issue.message) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add feed", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: draft.kind) { focus.issue = nil }
    }

    private func input(_ name: String, _ hint: String, _ binding: Binding<String>, _ field: FeedInput) -> some View {
        InputLabel(name: name) {
            TextField(name, text: binding, prompt: Text(hint))
                .labelsHidden()
                .feedInput(field, value: binding.wrappedValue, focus: focus)
        }
    }

    private func save() {
        do {
            let monitor = try draft.monitor()
            onSave(monitor)
            dismiss()
        } catch let problem as FormIssue {
            focus.report(problem)
        } catch {
            focus.report(FormIssue(.title, "Check the monitor details and try again."))
        }
    }
}

private extension Credential {
    var purpose: String {
        switch self {
        case .finnhub: return "Stock quotes"
        case .serpapi: return "One-way flight prices"
        }
    }

    var dashboard: URL {
        switch self {
        case .finnhub: return URL(string: "https://finnhub.io/dashboard")!
        case .serpapi: return URL(string: "https://serpapi.com/manage-api-key")!
        }
    }
}

struct ProviderSettingsView: View {
    var provider: Credential? = nil
    @State private var selected: Credential?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let service = provider ?? selected {
            ProviderKeyEditor(service: service)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                FormHeader(title: "Provider keys", icon: "key")
                ForEach(Credential.allCases, id: \.self) { service in
                    Button {
                        selected = service
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(service.providerName).font(.headline)
                                Text(service.purpose).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding(6).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
                Divider()
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .modifier(FormSurface())
        }
    }
}

private struct ProviderKeyEditor: View {
    let service: Credential
    @Environment(\.dismiss) private var dismiss
    @State private var stored: Bool?
    @State private var errorMessage: String?
    @State private var confirmRemoval = false
    @State private var entry = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormHeader(title: "Connect " + service.providerName, icon: "key")
            HStack {
                Text(service.purpose).foregroundStyle(.secondary)
                Spacer()
                Link(destination: service.dashboard) { Label("Get key", systemImage: "arrow.up.right") }
                    .accessibilityLabel("Get a \(service.providerName) API key")
            }
            SecureField("\(service.providerName) API key", text: $entry,
                        prompt: Text(stored == true ? "Enter a replacement key" : "Paste API key"))
                .accessibilityLabel("\(service.providerName) API key")
                .focused($focused)
            Text("Keys are saved in your Mac’s Keychain.").font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                FormErrorText(message: errorMessage)
                if stored == nil { Button("Retry") { Task { await load() } } }
            }
            Divider()
            HStack {
                if stored == true { Button("Remove key…") { confirmRemoval = true } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save key") { submit(removing: false) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(entry.trimmed.isEmpty || stored == nil)
            }
        }
        .modifier(FormSurface())
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .task { focused = true; await load() }
        .alert("Remove the \(service.providerName) key?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove key", role: .destructive) { submit(removing: true) }
        } message: { Text("Feeds using this key will need a replacement to refresh.") }
    }

    private func load() async {
        do {
            stored = try await KeyStore.shared.hasKey(service)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t check the \(service.providerName) key. \(error.localizedDescription)"
        }
    }

    private func submit(removing: Bool) {
        guard !saving else { return }
        let value = removing ? "" : entry.trimmed
        guard removing || (!value.isEmpty && value.utf8.allSatisfy({ (33...126).contains($0) })) else {
            errorMessage = "Paste the key exactly as shown in the provider dashboard."
            focused = true
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await KeyStore.shared.write(value, for: service)
                dismiss()
            } catch {
                errorMessage = "Couldn’t update the \(service.providerName) key. \(error.localizedDescription)"
            }
        }
    }
}
