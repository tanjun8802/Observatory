import SwiftUI

private enum FeedFilter: String, CaseIterable, Identifiable {
    case all = "All", stocks = "Stocks", flights = "Flights", custom = "Custom", codex = "Codex"
    var id: Self { self }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .stocks: return "chart.line.uptrend.xyaxis"
        case .flights: return "airplane"
        case .custom: return "curlybraces"
        case .codex: return "text.bubble"
        }
    }

    init(_ kind: MonitorKind) {
        switch kind {
        case .stock: self = .stocks
        case .flight: self = .flights
        case .json: self = .custom
        case .codex: self = .codex
        }
    }

    func includes(_ monitor: Monitor) -> Bool {
        self == .all || self == FeedFilter(monitor.kind)
    }
}

struct DashboardView: View {
    @Environment(\.boardPalette) private var ink
    @ObservedObject var store: DashboardStore
    var add: () -> Void
    var settings: () -> Void
    var connect: (Credential) -> Void = { _ in }
    var track: (String, Reading) -> Void = { _, _ in }
    var edit: (Monitor) -> Void = { _ in }
    @AppStorage("boardTheme") private var theme = BoardTheme.evergreen
    @State private var selected: FeedFilter = .all
    @State private var arranging = false

    var body: some View {
        GeometryReader { bounds in
            let slim = bounds.size.width < 890
            let railWidth: CGFloat = slim ? 60 : 170
            let inset: CGFloat = bounds.size.width < 890 ? 16 : 20
            let contentWidth = max(0, bounds.size.width - railWidth - 1 - 2 * inset)
            HStack(spacing: 0) {
                sidebar(slim: slim)
                    .frame(width: railWidth)
                Rectangle().fill(ink.rule).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        header(compact: contentWidth < 780)
                        QueryBoard(track: track, addFeed: store.add)
                        feedSection
                    }
                    .padding(.horizontal, inset)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .frame(maxWidth: 1600)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(ink.background)
        .foregroundStyle(ink.text)
    }

    private func sidebar(slim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ObservatoryMark().frame(width: 28, height: 28)
                if !slim {
                    Text("Observatory")
                        .font(.system(size: 18, weight: .medium, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
            }
            .frame(maxWidth: .infinity, alignment: slim ? .center : .leading)
            .padding(.horizontal, slim ? 0 : 17)
            .padding(.top, 27)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Observatory")

            VStack(spacing: 4) {
                ForEach(FeedFilter.allCases) { item in
                    let active = selected == item
                    Button {
                        selected = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .frame(width: 18)
                            if !slim {
                                Text(item.rawValue)
                                Spacer(minLength: 0)
                                Text("\(store.monitors.filter(item.includes).count)")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: slim ? .center : .leading)
                        .padding(.horizontal, slim ? 0 : 12)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DashboardButtonStyle(fill: active ? ink.accent.opacity(0.1) : .clear))
                    .foregroundStyle(active ? ink.accent : ink.secondary)
                    .help(item.rawValue)
                    .accessibilityLabel(item.rawValue)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, slim ? 9 : 12)
            .padding(.top, 38)
            Spacer(minLength: 12)
            Rectangle().fill(ink.rule).frame(height: 1)
                .padding(.horizontal, 15)
            Menu {
                Picker("Theme", selection: $theme) {
                    ForEach(BoardTheme.allCases, id: \.self) { ThemeChoice(theme: $0).tag($0) }
                }
            } label: {
                Label(slim ? "" : "Theme", systemImage: "paintpalette")
                    .frame(maxWidth: .infinity, alignment: slim ? .center : .leading)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Theme")
            .padding(.horizontal, slim ? 14 : 20)
            .padding(.top, 14)
            Button(action: settings) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                    if !slim { Text("Settings") }
                }
                .frame(maxWidth: .infinity, alignment: slim ? .center : .leading)
                .padding(.horizontal, slim ? 0 : 12)
                .frame(height: 35)
            }
            .buttonStyle(DashboardButtonStyle())
            .foregroundStyle(ink.secondary)
            .accessibilityLabel("Settings")
            .help("Settings")
            .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(ink.rail)
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 8) {
            LocalClock(compact: compact)
            Spacer(minLength: 0)
            Button {
                store.refreshAll()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.clockwise")
                    if !compact { Text("Refresh") }
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
            }
            .buttonStyle(DashboardButtonStyle(stroke: ink.rule))
            .disabled(store.monitors.allSatisfy { $0.isPaused || store.refreshing.contains($0.id) })
            .accessibilityLabel("Refresh all feeds")
            .help("Refresh all feeds")
            Button(action: add) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    if !compact { Text("Add feed") }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
            }
            .buttonStyle(DashboardButtonStyle(fill: ink.accent))
            .foregroundStyle(ink.background)
            .accessibilityLabel("Add feed")
            .help("Add feed")
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private var feedSection: some View {
        let monitors = store.monitors.filter(selected.includes)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(selected == .all ? "Your feeds" : selected.rawValue)
                    .font(.system(size: 22, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Text(String(format: "%02d", monitors.count))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.secondary)
                Spacer()
                if monitors.contains(where: { store.errors[$0.id] != nil && !$0.isPaused }) {
                    Button("Retry failed") { store.retryFailed(monitors) }
                        .disabled(!monitors.contains { store.errors[$0.id] != nil && !$0.isPaused && !store.refreshing.contains($0.id) })
                        .help("Retry failed feeds in this view")
                }
                if arranging && selected == .all && !store.monitors.isEmpty {
                    Button("Fit squares") { store.arrangeAsSquares() }
                        .help("Arrange all feeds in equal square tiles")
                }
                if !store.monitors.isEmpty {
                    Button {
                        arranging.toggle()
                    } label: {
                        Label(arranging ? "Done" : "Arrange", systemImage: arranging ? "checkmark" : "rectangle.3.group")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 28)
                    }
                    .buttonStyle(DashboardButtonStyle(fill: arranging ? ink.raised : .clear, stroke: ink.rule))
                    .foregroundStyle(arranging ? ink.accent : ink.text)
                    .accessibilityLabel(arranging ? "Finish arranging widgets" : "Arrange widgets")
                }
            }
            if monitors.isEmpty {
                EmptyFeeds(filter: selected, add: add)
            } else {
                let authenticationIssues = store.authenticationIssues
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    FeedCanvas(monitors: monitors, layout: store.layout, arranging: arranging,
                               commit: store.placeWidget) { monitor, width in
                        FeedCard(monitor: monitor, reading: store.readings[monitor.id],
                                 error: store.errors[monitor.id], checked: store.lastChecked[monitor.id],
                                 nextRun: store.nextRefresh(for: monitor),
                                 refreshing: store.refreshing.contains(monitor.id), now: tick.date,
                                 width: width, refresh: { store.refresh(monitor) },
                                 credentialToConnect: authenticationIssues.contains(monitor.id) ? monitor.credential : nil,
                                 connect: connect, edit: { edit(monitor) },
                                 setTheme: { store.setTheme($0, for: monitor.id) },
                                 togglePause: { store.setPaused(!monitor.isPaused, for: monitor) },
                                 remove: { store.remove(monitor) })
                    }
                }
            }
        }
    }
}

private struct ObservatoryMark: View {
    @Environment(\.boardPalette) private var ink
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            context.stroke(Path(ellipseIn: rect), with: .color(ink.accent), lineWidth: 1.5)
            var axis = Path()
            axis.move(to: CGPoint(x: 1, y: size.height * 0.76))
            axis.addLine(to: CGPoint(x: size.width - 1, y: size.height * 0.24))
            context.stroke(axis, with: .color(ink.accent), lineWidth: 1.5)
            context.fill(Path(ellipseIn: CGRect(x: size.width * 0.53, y: size.height * 0.24,
                                                width: 4, height: 4)), with: .color(ink.coral))
        }
        .accessibilityHidden(true)
    }
}

private struct DashboardButtonStyle: ButtonStyle {
    var fill: Color = .clear
    var stroke: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        ButtonSurface(configuration: configuration, fill: fill, stroke: stroke)
    }

    private struct ButtonSurface: View {
        let configuration: ButtonStyle.Configuration
        let fill: Color
        let stroke: Color
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(fill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(.white.opacity(configuration.isPressed ? 0.13 : (hover && enabled ? 0.07 : 0)))
                        }
                }
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(stroke) }
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover = $0 }
        }
    }
}

struct InstrumentPanel: ViewModifier {
    @Environment(\.boardPalette) private var ink
    func body(content: Content) -> some View {
        content.background { RoundedRectangle(cornerRadius: ink.corner).fill(ink.surface) }
            .clipShape(RoundedRectangle(cornerRadius: ink.corner))
            .overlay { RoundedRectangle(cornerRadius: ink.corner).strokeBorder(ink.rule) }
    }

}

extension View {
    func instrumentPanel() -> some View { modifier(InstrumentPanel()) }
}

private struct LocalClock: View {
    let compact: Bool
    @Environment(\.boardPalette) private var ink

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let date = tick.date
            let zone = TimeZone.autoupdatingCurrent
            HStack(spacing: compact ? 12 : 18) {
                Text(date, format: Date.VerbatimFormatStyle(
                    format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                    timeZone: zone, calendar: .autoupdatingCurrent))
                    .font(.system(size: compact ? 48 : 64, weight: .light))
                    .tracking(-2)
                    .monospacedDigit()
                    .foregroundStyle(ink.accent)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(date, format: .dateTime.weekday(.wide))
                        if let name = zone.abbreviation(for: date) {
                            Text(verbatim: name)
                                .font(.caption.monospaced())
                        }
                    }
                    .font(.system(size: compact ? 14 : 16, weight: .medium))
                    .foregroundStyle(ink.secondary)
                    Text(date, format: .dateTime.month(.wide).day())
                        .font(.system(size: compact ? 23 : 28, design: .serif))
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Local date and time")
            .accessibilityValue(date.formatted(date: .complete, time: .shortened))
        }
    }
}

private struct EmptyFeeds: View {
    @Environment(\.boardPalette) private var ink
    let filter: FeedFilter
    let add: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .all ? "dot.radiowaves.left.and.right" : filter.icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(ink.accent)
                .frame(width: 48, height: 48)
                .background { Circle().fill(ink.accent.opacity(0.055)) }
                .overlay { Circle().strokeBorder(ink.accent.opacity(0.17)) }
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 22, design: .serif))
            Text("Add a feed to follow its latest reading here.")
                .font(.system(size: 12))
                .foregroundStyle(ink.secondary)
            Button(action: add) {
                Label("Add feed", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 28)
            }
            .buttonStyle(DashboardButtonStyle(stroke: ink.rule))
            .foregroundStyle(ink.accent)
            .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(22)
        .frame(maxWidth: .infinity)
        .instrumentPanel()
    }

    private var title: String {
        switch filter {
        case .all: return "No feeds yet"
        case .stocks: return "No stock feeds yet"
        case .flights: return "No flight feeds yet"
        case .custom: return "No custom feeds yet"
        case .codex: return "No Codex feeds yet"
        }
    }
}

private struct FeedCard: View {
    @Environment(\.boardPalette) private var ink
    @State private var showingDetails = false
    let monitor: Monitor
    let reading: Reading?
    let error: String?
    let checked: Date?
    let nextRun: Date?
    let refreshing: Bool
    let now: Date
    let width: CGFloat
    let refresh: () -> Void
    let credentialToConnect: Credential?
    let connect: (Credential) -> Void
    let edit: () -> Void
    let setTheme: (BoardTheme?) -> Void
    let togglePause: () -> Void
    let remove: () -> Void

    private var source: String {
        switch monitor.kind {
        case .codex: return "Codex, " + (monitor.schedule?.label ?? "On demand")
        case .stock: return ["Finnhub", monitor.symbol].filter { !$0.isEmpty }.joined(separator: ", ")
        case .flight:
            let route = [monitor.origin, monitor.destination].filter { !$0.isEmpty }.joined(separator: " → ")
            return ["Google Flights via SerpApi", route].filter { !$0.isEmpty }.joined(separator: ", ")
        case .json: return URLComponents(string: monitor.endpoint)?.host ?? "Custom JSON"
        }
    }

    private var stale: Bool {
        guard let reading else { return false }
        if monitor.kind == .codex {
            return !monitor.isPaused && nextRun.map { $0 <= now } == true
        }
        return error != nil || now.timeIntervalSince(reading.observedAt) >= monitor.kind.refreshInterval
    }

    private var state: String {
        if refreshing { return monitor.kind == .codex ? "Running" : "Refreshing" }
        if monitor.isPaused { return "Paused" }
        if error != nil { return reading == nil ? "Error" : "Update failed" }
        if monitor.kind == .codex {
            if monitor.schedule == nil || monitor.schedule == .manual { return "On demand" }
            if case .once(let due) = monitor.schedule, let reading, reading.observedAt >= due, nextRun == nil {
                return "Completed"
            }
            if reading == nil { return "Pending" }
        }
        if stale { return "Stale" }
        return reading == nil ? "Awaiting reading" : "Available"
    }

    private var nextRunLabel: String {
        if monitor.isPaused { return "Paused" }
        if let nextRun {
            return nextRun <= now ? "Due now" : nextRun.formatted(date: .abbreviated, time: .shortened)
        }
        if monitor.schedule == nil || monitor.schedule == .manual { return "On demand" }
        return "None scheduled"
    }

    var body: some View {
        GeometryReader { proxy in
            if let reading, reading.presentation?.kind == .list, width >= 125, proxy.size.height >= 115 {
                listTile(reading)
            } else {
                ScrollView(.vertical) {
                    if width < 150 || proxy.size.height < 130 {
                        compactTile
                    } else if width < 415 {
                        tile(minimumHeight: proxy.size.height)
                    } else {
                        contents
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .popover(isPresented: $showingDetails) {
            ScrollView { contents }
                .frame(width: 360, height: 340)
                .background(ink.surface)
                .foregroundStyle(ink.text)
                .environment(\.boardPalette, ink)
                .tint(ink.accent)
                .preferredColorScheme(monitor.theme?.scheme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func listTile(_ reading: Reading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(monitor.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2).help(monitor.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if width < 210 { actionsMenu(compact: true) } else { actions }
            }
            if reading.presentation?.isPartial == true { PartialReadingLabel() }
            FeedListView(introduction: reading.value, rows: reading.presentation?.rows ?? [])
            if let error {
                Text(verbatim: error).font(.caption).foregroundStyle(ink.coral).lineLimit(2)
            }
            HStack { status; Spacer(minLength: 4); detailsButton }
        }
        .padding(8)
    }

    private var compactTile: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text(monitor.title).font(.caption.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(monitor.title)
                actionsMenu(compact: true)
            }
            if reading?.presentation?.isPartial == true { PartialReadingLabel() }
            Button { showingDetails = true } label: {
                VStack(alignment: .leading, spacing: 1) {
                    if let reading {
                        HStack(spacing: 4) {
                            Text(verbatim: reading.compactTileValue)
                                .font(.system(size: 22, weight: .medium, design: ink.figureFace).monospacedDigit())
                                .lineLimit(1).minimumScaleFactor(0.65)
                            if let symbol = reading.presentation?.weatherSymbol {
                                Image(systemName: symbol).font(.callout)
                            }
                        }
                        if let location = reading.presentation?.location {
                            Text(verbatim: location).font(.caption).lineLimit(1)
                        }
                    } else {
                        Text(state).font(.callout).foregroundStyle(error == nil ? ink.secondary : ink.coral)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show full reading and feed details")
            .accessibilityLabel("Details for \(monitor.title)")
            if let error, reading != nil {
                Button(action: refresh) {
                    Label("Retry update", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(ink.coral)
                }
                .buttonStyle(.plain).disabled(refreshing)
                .help(error)
                .accessibilityHint("The tile is showing its last successful reading.")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }

    private func tile(minimumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 3) {
                Text(monitor.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .help(monitor.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            Spacer(minLength: 0)
            if let reading {
                if reading.presentation?.isPartial == true { PartialReadingLabel() }
                TileReading(reading: reading, kind: monitor.kind)
                if monitor.kind != .codex, !reading.detail.isEmpty {
                    Text(verbatim: reading.detail).font(.caption).foregroundStyle(ink.secondary).lineLimit(2)
                }
            } else if let error {
                Text(error).font(.callout).foregroundStyle(ink.coral).lineLimit(2)
            }
            providerRecovery
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                HStack { status; Spacer(minLength: 4); detailsButton }
                VStack(alignment: .leading, spacing: 4) { status; detailsButton }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .frame(minHeight: minimumHeight, alignment: .topLeading)
    }

    @ViewBuilder private var providerRecovery: some View {
        if let credential = credentialToConnect {
            Button("Connect " + credential.providerName) { connect(credential) }
                .controlSize(.small)
        }
        if error != nil, let search = RoundTripFlightFeed.search(for: monitor) {
            Link("Open Google Flights", destination: search.publicURL).font(.caption)
        }
    }

    private var detailsButton: some View {
        Button("Details") { showingDetails = true }
            .buttonStyle(.link)
            .accessibilityLabel("Details for \(monitor.title)")
    }

    private var identity: some View {
        HStack(spacing: 8) {
            Image(systemName: FeedFilter(monitor.kind).icon)
                .font(.system(size: 15))
                .foregroundStyle(monitor.kind == .flight ? ink.coral : ink.accent)
                .frame(width: 31, height: 31)
                .background { RoundedRectangle(cornerRadius: 7).fill(ink.raised) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(monitor.title).font(.system(size: 15, weight: .semibold))
                Text(monitor.kind == .codex ? source : (reading.flatMap { $0.detail.isEmpty ? nil : $0.detail } ?? source))
                    .font(.system(size: 11)).foregroundStyle(ink.secondary)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button(action: refresh) {
            if monitor.kind == .codex && width < 360 {
                Image(systemName: "play.fill").frame(width: 26, height: 26)
            } else if monitor.kind == .codex {
                Label("Run now", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(height: 26)
            } else {
                Image(systemName: "arrow.clockwise").frame(width: 26, height: 26)
            }
        }
        .buttonStyle(DashboardButtonStyle())
        .disabled(refreshing)
        .accessibilityLabel(monitor.kind == .codex ? "Run \(monitor.title) now" : "Refresh \(monitor.title)")
        .help(monitor.kind == .codex ? "Run now" : "Refresh feed")
        actionsMenu(compact: false)
    }

    private func actionsMenu(compact: Bool) -> some View {
        Menu {
            if compact {
                Button("Details") { showingDetails = true }
                Button(monitor.kind == .codex ? "Run now" : "Refresh", action: refresh).disabled(refreshing)
                Divider()
            }
            Menu("Feed theme") {
                Picker("Feed theme", selection: Binding(get: { monitor.theme }, set: setTheme)) {
                    Text("Use dashboard theme").tag(nil as BoardTheme?)
                    ForEach(BoardTheme.allCases, id: \.self) { theme in
                        ThemeChoice(theme: theme).tag(Optional(theme))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            if monitor.kind == .codex {
                Button("Edit prompt & schedule…", action: edit)
                Button(monitor.isPaused ? "Resume" : "Pause", action: togglePause)
                Divider()
            }
            Button("Remove feed", role: .destructive, action: remove)
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(monitor.title)")
        .help("Feed actions")
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 6) {
            if width < 225 {
                identity
                HStack(spacing: 6) {
                    status
                    Spacer(minLength: 0)
                    actions
                }
            } else {
                HStack(spacing: 8) {
                    identity
                    Spacer(minLength: 0)
                    if width >= 550 { status }
                    HStack(spacing: 4) { actions }.fixedSize()
                }
                if width < 550 { status }
            }
            if let reading {
                FeedReadingView(reading: reading, kind: monitor.kind)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(ink.coral)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            providerRecovery
            if monitor.kind == .codex || reading != nil || checked != nil {
                Rectangle().fill(ink.rule).frame(height: 1)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { timestamps }
                    VStack(alignment: .leading, spacing: 4) { timestamps }
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(ink.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: some View {
        HStack(spacing: 5) {
            if refreshing {
                ProgressView().controlSize(.mini)
            } else if error != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(ink.coral)
                    .accessibilityHidden(true)
            }
            Text(state)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ink.secondary)
        }
    }

    @ViewBuilder private var timestamps: some View {
        if monitor.kind == .codex {
            Text("Next run  \(nextRunLabel)")
            Text("Last success  \(reading?.observedAt.formatted(date: .abbreviated, time: .shortened) ?? "Never")")
        } else {
            if let reading {
                Text("Observed \(reading.observedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            if let checked {
                Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
}
