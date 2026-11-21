import CoreGraphics
import Foundation

/// Logical coordinates do not depend on the window width, feed filter, or reading.
struct WidgetPlacement: Codable, Equatable {
    var column: Int
    var row: Int
    var width: Int
    var height: Int

    var bottom: Int { row + height }

    func overlaps(_ other: Self) -> Bool {
        column < other.column + other.width && other.column < column + width &&
        row < other.bottom && other.row < bottom
    }
}

struct CanvasLayout: Equatable, Codable {
    static let columns = 24
    static let version = 3
    static let tileSide = 6
    static let minimumWidth = 4
    static let minimumHeight = 2
    static let gap: CGFloat = 8

    private(set) var placements: [UUID: WidgetPlacement] = [:]

    static func columnPitch(for width: CGFloat) -> CGFloat {
        (width + gap) / CGFloat(columns)
    }

    static func frame(for placement: WidgetPlacement, in width: CGFloat) -> CGRect {
        let pitch = columnPitch(for: width)
        let x: CGFloat = CGFloat(placement.column) * pitch
        let y: CGFloat = CGFloat(placement.row) * pitch
        let cardWidth: CGFloat = CGFloat(placement.width) * pitch - gap
        let cardHeight: CGFloat = CGFloat(placement.height) * pitch - gap
        return CGRect(x: x, y: y, width: cardWidth, height: cardHeight)
    }

    func fits(_ placement: WidgetPlacement, for id: UUID) -> Bool {
        // Bound decoded coordinates before adding them or converting them to display geometry.
        guard (Self.minimumWidth...Self.columns).contains(placement.width),
              (0...(Self.columns - placement.width)).contains(placement.column),
              (Self.minimumHeight...1_000_000).contains(placement.height),
              (0...1_000_000).contains(placement.row) else { return false }
        return !placements.contains { $0.key != id && $0.value.overlaps(placement) }
    }

    /// Keyboard moves skip occupied cells, so a widget can leave even a densely packed row.
    func nextMove(for id: UUID, columns dx: Int, rows dy: Int) -> WidgetPlacement? {
        guard let start = placements[id] else { return nil }
        var target = WidgetEdit.move.candidate(from: start, columns: dx, rows: dy)
        while target != start, target.row >= 0, target.column >= 0, target.column + target.width <= Self.columns {
            if fits(target, for: id) { return target }
            let blockers = placements.filter { $0.key != id && $0.value.overlaps(target) }.values
            guard !blockers.isEmpty else { return nil }
            if dy > 0 { target.row = blockers.map(\.bottom).max()! }
            else if dy < 0 { target.row = blockers.map(\.row).min()! - target.height }
            else { target.column += dx }
        }
        return nil
    }

    @discardableResult
    mutating func set(_ placement: WidgetPlacement, for id: UUID) -> Bool {
        guard placements[id] != placement, fits(placement, for: id) else { return false }
        placements[id] = placement
        return true
    }

    mutating func insert(_ monitor: Monitor) {
        insert(monitor.id, width: Self.tileSide, height: Self.tileSide)
    }

    private mutating func insert(_ id: UUID, width: Int, height: Int) {
        guard placements[id] == nil else { return }
        var proposed = WidgetPlacement(column: 0, row: 0, width: width, height: height)
        // The first usable row is either zero or the lower edge of an occupied rectangle.
        for row in Set(placements.values.map(\.bottom)).union([0]).sorted() {
            proposed.row = row
            for column in 0...(Self.columns - proposed.width) {
                proposed.column = column
                if set(proposed, for: id) { return }
            }
        }
    }

    mutating func remove(_ id: UUID) {
        placements.removeValue(forKey: id)
    }

    /// Reserve all surviving saved cells before assigning defaults to new or invalid entries.
    init() {}

    init(monitors: [Monitor], saved: CanvasLayout? = nil, savedVersion: Int = Self.version) {
        var reserved = saved?.placements ?? [:]
        if savedVersion < Self.version, !reserved.isEmpty {
            // Versions 1 and 2 both used six columns. Scale the horizontal coordinates
            // before comparing the old automatic layout or restoring a manual layout.
            let scale = Self.columns / 6
            reserved = reserved.compactMapValues { cell in
                guard (2...6).contains(cell.width), (0...(6 - cell.width)).contains(cell.column) else { return nil }
                return WidgetPlacement(column: cell.column * scale, row: cell.row,
                                       width: cell.width * scale, height: cell.height)
            }
            var automatic = CanvasLayout()
            for monitor in monitors {
                let oldWidth = savedVersion == 1 ? 3 : 2
                let short = savedVersion == 2 && reserved[monitor.id]?.height == 4
                let oldHeight = monitor.kind == .codex && !short ? 7 : 4
                automatic.insert(monitor.id, width: oldWidth * scale, height: oldHeight)
            }
            if automatic.placements == reserved { reserved.removeAll() }
        }
        for monitor in monitors {
            if let cell = reserved[monitor.id] { set(cell, for: monitor.id) }
        }
        for monitor in monitors where placements[monitor.id] == nil { insert(monitor) }
    }

    // Store a JSON object with UUID keys. An unreadable entry only resets that widget.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: WidgetKey.self) else { return }
        for key in container.allKeys {
            guard let id = UUID(uuidString: key.stringValue),
                  let cell = try? container.decode(WidgetPlacement.self, forKey: key) else { continue }
            placements[id] = cell
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WidgetKey.self)
        for (id, placement) in placements {
            try container.encode(placement, forKey: WidgetKey(stringValue: id.uuidString))
        }
    }

    private struct WidgetKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

enum WidgetEdit {
    case move, resize

    func candidate(from start: WidgetPlacement, columns dx: Int, rows dy: Int) -> WidgetPlacement {
        var result = start
        switch self {
        case .move:
            result.column = min(max(0, start.column + dx), CanvasLayout.columns - start.width)
            result.row = max(0, start.row + dy)
        case .resize:
            result.width = min(max(CanvasLayout.minimumWidth, start.width + dx), CanvasLayout.columns - start.column)
            result.height = max(CanvasLayout.minimumHeight, start.height + dy)
        }
        return result
    }

    func candidate(from start: WidgetPlacement, translation: CGSize, canvasWidth: CGFloat) -> WidgetPlacement {
        let dx = Int((translation.width / CanvasLayout.columnPitch(for: canvasWidth)).rounded())
        let dy = Int((translation.height / CanvasLayout.columnPitch(for: canvasWidth)).rounded())
        return candidate(from: start, columns: dx, rows: dy)
    }
}
