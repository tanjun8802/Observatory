import SwiftUI

/// Reading content for a feed card. The surrounding card owns its title, status and timestamps.
struct FeedReadingView: View {
    let reading: Reading
    let kind: MonitorKind

    @Environment(\.boardPalette) private var ink
    @State private var showsFullReading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let presentation = reading.presentation {
                if presentation.isPartial == true { PartialReadingLabel() }
                let metrics = presentation.metrics.filter { $0.value.isFinite }
                if presentation.kind == .list {
                    FeedListView(introduction: reading.value, rows: presentation.rows ?? [])
                        .frame(idealHeight: 220, maxHeight: 280)
                    attribution(presentation)
                } else if presentation.kind != .summary, let first = metrics.first {
                    if presentation.kind == .weather {
                        weather(presentation, primary: first, secondary: Array(metrics.dropFirst()))
                    } else {
                        measurements(primary: first, secondary: Array(metrics.dropFirst()))
                    }
                    footer(presentation, offersFullReading: !reading.value.isEmpty)
                } else {
                    prose
                    attribution(presentation)
                }
            } else {
                prose
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(ink.accent)
    }

    private var prose: some View {
        let large = reading.presentation == nil && (kind == .stock || kind == .flight)
        return Text(linkedText)
            .font(large ? .system(.largeTitle, design: .rounded, weight: .medium) : .body)
            .foregroundStyle(large ? ink.accent : ink.text)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityHint(Text(verbatim: reading.detail))
    }

    // Keep provider text verbatim while making its public results links clickable.
    private var linkedText: AttributedString {
        var text = AttributedString(reading.value)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        let range = NSRange(reading.value.startIndex..., in: reading.value)
        for match in detector.matches(in: reading.value, range: range) {
            guard let url = match.url, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  let sourceRange = Range(match.range, in: reading.value),
                  let targetRange = Range(sourceRange, in: text) else { continue }
            text[targetRange].link = url
        }
        return text
    }

    private func weather(_ card: FeedPresentation, primary: FeedMetric, secondary: [FeedMetric]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let location = card.location, !location.isEmpty {
                        Text(verbatim: location)
                            .font(.system(.title2, design: .serif, weight: .medium))
                            .foregroundStyle(ink.text)
                            .accessibilityAddTraits(.isHeader)
                    }
                    MetricValue(metric: primary, size: 42)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: primary.label))
                        .accessibilityValue(Text(verbatim: primary.spokenValue))
                    if let condition = card.condition, !condition.isEmpty {
                        Text(verbatim: condition).font(.callout.weight(.medium)).foregroundStyle(ink.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let symbol = card.weatherSymbol, FeedPresentation.weatherSymbols.contains(symbol) {
                    WeatherEmblem(symbol: symbol)
                }
            }
            .padding(10)
            if !secondary.isEmpty {
                Rectangle().fill(ink.rule).frame(height: 1)
                secondaryMeasures(secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ink.surface.opacity(0.48))
            }
        }

    }

    private func measurements(primary: FeedMetric, secondary: [FeedMetric]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: primary.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ink.secondary)
                MetricValue(metric: primary, size: 42)
            }
            .accessibilityElement(children: .combine)
            if !secondary.isEmpty {
                Rectangle().fill(ink.rule).frame(height: 1)
                secondaryMeasures(secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)

    }

    private func secondaryMeasures(_ metrics: [FeedMetric]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 102), spacing: 16, alignment: .topLeading)],
                  alignment: .leading, spacing: 12) {
            ForEach(metrics.indices, id: \.self) { index in
                let metric = metrics[index]
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: metric.label).font(.caption.weight(.medium)).foregroundStyle(ink.secondary)
                    MetricValue(metric: metric, size: 19)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func footer(_ card: FeedPresentation, offersFullReading: Bool) -> some View {
        if offersFullReading {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    readingToggle
                    Spacer(minLength: 0)
                    attribution(card)
                }
                VStack(alignment: .leading, spacing: 8) {
                    readingToggle
                    attribution(card)
                }
            }
            if showsFullReading { prose }
        } else {
            attribution(card)
        }
    }

    private var readingToggle: some View {
        Button {
            showsFullReading.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsFullReading ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                Text("Full reading")
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(ink.secondary)
        .accessibilityValue(showsFullReading ? "Expanded" : "Collapsed")
    }

    @ViewBuilder
    private func attribution(_ card: FeedPresentation) -> some View {
        let name = card.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = card.sourceURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host(), !host.isEmpty, url.user() == nil, url.password() == nil {
            let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? host
            Link(destination: url) {
                HStack(spacing: 4) {
                    Text(verbatim: label)
                }
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(ink.accent)
            .help(url.absoluteString)
            .accessibilityLabel(Text("Source: \(label)"))
        } else if let name, !name.isEmpty {
            Text(verbatim: name).font(.callout).foregroundStyle(ink.secondary)
                .accessibilityLabel(Text("Source: \(name)"))
        }
    }
}

struct PartialReadingLabel: View {
    @Environment(\.boardPalette) private var ink

    var body: some View {
        Label("Partial update", systemImage: "circle.lefthalf.filled")
            .font(.caption.weight(.medium))
            .foregroundStyle(ink.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Partial update")
    }
}

/// Keeps the introduction and every row within one vertically scrollable reading.
struct FeedListView: View {
    let introduction: String
    let rows: [FeedRow]
    @Environment(\.boardPalette) private var ink

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !introduction.isEmpty || rows.isEmpty {
                    Text(verbatim: introduction.isEmpty ? "No items." : introduction)
                        .font(.callout)
                        .foregroundStyle(ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.vertical, 5)
                }
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    if index > 0 || !introduction.isEmpty {
                        Rectangle().fill(ink.rule).frame(height: 1).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if let url = row.link {
                            Link(destination: url) {
                                (Text(verbatim: row.title) + Text(" ") + Text(Image(systemName: "arrow.up.right")))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(ink.accent)
                            .accessibilityLabel(Text(verbatim: row.title))
                            .help(url.absoluteString)
                        } else {
                            Text(verbatim: row.title).foregroundStyle(ink.text)
                        }
                        if !row.detail.isEmpty {
                            Text(verbatim: row.detail).font(.caption).foregroundStyle(ink.secondary)
                        }
                        if !row.value.isEmpty {
                            Text(verbatim: row.value).font(.callout.weight(.medium)).foregroundStyle(ink.text)
                        }
                    }
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5)
                    .accessibilityElement(children: .contain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityLabel("Reading items")
    }
}

/// The tile shows the primary measurement. Its Details button opens the complete reading.
struct TileReading: View {
    let reading: Reading
    let kind: MonitorKind
    @Environment(\.boardPalette) private var ink

    var body: some View {
        if let card = reading.presentation, card.kind != .summary,
           let metric = card.metrics.first, metric.value.isFinite {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: card.kind == .weather ? card.location ?? metric.label : metric.label)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    MetricValue(metric: metric, size: 34)
                    if card.kind == .weather, let symbol = card.weatherSymbol {
                        Spacer(minLength: 0)
                        Image(systemName: symbol)
                            .font(.system(size: 25))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(ink.text, ink.coral, ink.accent)
                            .accessibilityHidden(true)
                    }
                }
                if let condition = card.condition {
                    Text(verbatim: condition).font(.callout).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let isValue = kind != .codex && reading.value.count <= 16
            Text(verbatim: reading.value)
                .font(isValue ? .system(size: 27, weight: .medium, design: ink.figureFace) : .body)
                .foregroundStyle(isValue ? ink.accent : ink.text)
                .lineLimit(isValue ? 2 : 3)
                .textSelection(.enabled)
        }
    }
}

private struct WeatherEmblem: View {
    let symbol: String
    @Environment(\.boardPalette) private var ink

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.palette)
            .foregroundStyle(ink.text, ink.coral, ink.accent)
            .frame(width: 46, height: 46)
        .accessibilityHidden(true)
    }
}

private extension FeedMetric {
    var formattedNumber: String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...17))
        let magnitude = abs(value)
        if magnitude >= 1e15 || (magnitude > 0 && magnitude < 1e-6) {
            return value.formatted(style.notation(.scientific))
        }
        return value.formatted(style)
    }

    var spokenValue: String {
        [formattedNumber, unit].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct MetricValue: View {
    let metric: FeedMetric
    let size: CGFloat
    @Environment(\.boardPalette) private var ink

    var body: some View {
        ViewThatFits(in: .horizontal) {
            amount(at: size).fixedSize()
            amount(at: size * 0.78).fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }

    private func amount(at size: CGFloat) -> Text {
        let unit = metric.unit
        let separator = unit.isEmpty || unit.hasPrefix("°") || unit == "%" ? "" : " "
        let number = Text(verbatim: metric.formattedNumber)
            .font(.system(size: size, weight: .medium, design: ink.figureFace).monospacedDigit())
            .foregroundColor(ink.text)
        let suffix = Text(verbatim: separator + unit)
            .font(.system(size: max(13, size * 0.48), weight: .medium))
            .foregroundColor(ink.secondary)
        return number + suffix
    }
}

extension Reading {
    var compactTileValue: String {
        if presentation?.kind == .list {
            let count = presentation?.rows?.count ?? 0
            return count == 1 ? "1 item" : "\(count) items"
        }
        guard let metric = presentation?.metrics.first else { return value }
        let number = abs(metric.value) >= 1_000_000
            ? metric.value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
            : metric.formattedNumber
        let separator = metric.unit.hasPrefix("°") || metric.unit == "%" ? "" : " "
        return metric.unit.isEmpty ? number : number + separator + metric.unit
    }
}
