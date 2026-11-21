import SwiftUI

struct FeedCanvas<Card: View>: View {
    let monitors: [Monitor]
    let layout: CanvasLayout
    let arranging: Bool
    let commit: (UUID, WidgetPlacement) -> Void
    @ViewBuilder let card: (Monitor, CGFloat) -> Card

    @Environment(\.boardPalette) private var ink
    @Environment(\.colorScheme) private var scheme
    @Namespace private var canvasSpace
    @GestureState private var drag: DragTarget?

    private struct DragTarget {
        let id: UUID
        let cell: WidgetPlacement
    }

    var body: some View {
        let visibleIDs = Set(monitors.map(\.id))
        let visibleBottom = monitors.compactMap { layout.placements[$0.id]?.bottom }.max() ?? 0
        let allBottom = layout.placements.values.map(\.bottom).max() ?? 0
        let bottom = arranging ? max(allBottom + 3, drag?.cell.bottom ?? 0) : visibleBottom
        CanvasExtent(rows: bottom) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    if arranging {
                        grid(width: width)
                        ForEach(layout.placements.keys.filter { !visibleIDs.contains($0) }, id: \.self) { id in
                            if let cell = layout.placements[id] {
                                let rect = CanvasLayout.frame(for: cell, in: width)
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(ink.raised.opacity(0.55))
                                    .overlay { Text("Filtered feed").font(.caption).foregroundStyle(ink.secondary) }
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    ForEach(monitors) { monitor in
                        if let saved = layout.placements[monitor.id] {
                            let tileInk = monitor.theme?.palette ?? ink
                            let target = drag.flatMap { $0.id == monitor.id ? $0.cell : nil }
                            let cell = target.flatMap { layout.fits($0, for: monitor.id) ? $0 : nil } ?? saved
                            let rect = CanvasLayout.frame(for: cell, in: width)
                            VStack(spacing: 0) {
                                if arranging { arrangeBar(monitor, cell: saved, width: width, ink: tileInk) }
                                card(monitor, rect.width)
                                if arranging {
                                    resizeBar(monitor, cell: saved, display: cell, width: width, ink: tileInk)
                                }
                            }
                            .frame(width: rect.width, height: rect.height)
                            .instrumentPanel()
                            .overlay {
                                if target != nil {
                                    RoundedRectangle(cornerRadius: tileInk.corner).strokeBorder(tileInk.accent, lineWidth: 2)
                                        .allowsHitTesting(false)
                                }
                            }
                            .foregroundStyle(tileInk.text)
                            .tint(tileInk.accent)
                            .environment(\.boardPalette, tileInk)
                            .environment(\.colorScheme, monitor.theme?.scheme ?? scheme)
                            .offset(x: rect.minX, y: rect.minY)
                            .zIndex(target == nil ? 0 : 1)
                        }
                    }
                    if let drag, !layout.fits(drag.cell, for: drag.id) {
                        let rect = CanvasLayout.frame(for: drag.cell, in: width)
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(ink.coral, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            .overlay(alignment: .center) {
                                Text("Space occupied").font(.caption.weight(.semibold))
                                    .padding(6).background(ink.surface, in: Capsule()).foregroundStyle(ink.coral)
                            }
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                            .zIndex(2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .coordinateSpace(name: canvasSpace)
            }
        }
    }

    private func grid(width: CGFloat) -> some View {
        Canvas { context, size in
            let pitch = CanvasLayout.columnPitch(for: width)
            var lines = Path()
            for col in 0..<CanvasLayout.columns {
                let x = CGFloat(col) * pitch
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: CGFloat.zero, to: size.height, by: pitch) {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(ink.rule), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func arrangeBar(_ monitor: Monitor, cell: WidgetPlacement, width: CGFloat, ink: BoardPalette) -> some View {
        HStack(spacing: 4) {
            Label("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(gesture(.move, id: monitor.id, start: cell, width: width))
                .help("Drag to an open grid position")
                .accessibilityHidden(true)
            Menu {
                Section("Move to an open position") {
                    layoutButton("Move left", id: monitor.id, target: layout.nextMove(for: monitor.id, columns: -1, rows: 0))
                    layoutButton("Move right", id: monitor.id, target: layout.nextMove(for: monitor.id, columns: 1, rows: 0))
                    layoutButton("Move up", id: monitor.id, target: layout.nextMove(for: monitor.id, columns: 0, rows: -1))
                    layoutButton("Move down", id: monitor.id, target: layout.nextMove(for: monitor.id, columns: 0, rows: 1))
                }
                Section("Resize") {
                    layoutButton("Wider", id: monitor.id, target: WidgetEdit.resize.candidate(from: cell, columns: 1, rows: 0))
                    layoutButton("Narrower", id: monitor.id, target: WidgetEdit.resize.candidate(from: cell, columns: -1, rows: 0))
                    layoutButton("Taller", id: monitor.id, target: WidgetEdit.resize.candidate(from: cell, columns: 0, rows: 1))
                    layoutButton("Shorter", id: monitor.id, target: WidgetEdit.resize.candidate(from: cell, columns: 0, rows: -1))
                }
            } label: { Text("Layout").font(.caption.weight(.medium)) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Layout controls for \(monitor.title)")
            .accessibilityValue("Column \(cell.column + 1), row \(cell.row + 1), \(cell.width) columns wide, \(cell.height) rows tall")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .foregroundStyle(ink.accent)
        .background(ink.raised)
    }

    private func layoutButton(_ title: String, id: UUID, target: WidgetPlacement?) -> some View {
        Button(title) {
            if let target { commit(id, target) }
        }
        .disabled(target.map { layout.placements[id] == $0 || !layout.fits($0, for: id) } ?? true)
    }

    private func resizeBar(_ monitor: Monitor, cell: WidgetPlacement, display: WidgetPlacement, width: CGFloat, ink: BoardPalette) -> some View {
        HStack {
            Spacer()
            HStack(spacing: 7) {
                Text("\(display.width) × \(display.height)").font(.caption.monospacedDigit())
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(gesture(.resize, id: monitor.id, start: cell, width: width))
            .help("Drag to resize width and height")
            .accessibilityHidden(true)
        }
        .frame(height: 24)
        .foregroundStyle(ink.accent)
        .background(ink.raised)
    }

    private func gesture(_ edit: WidgetEdit, id: UUID, start: WidgetPlacement, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(canvasSpace))
            .updating($drag) { value, state, _ in
                state = DragTarget(id: id, cell: edit.candidate(from: start, translation: value.translation, canvasWidth: width))
            }
            .onEnded { value in
                let cell = edit.candidate(from: start, translation: value.translation, canvasWidth: width)
                if layout.fits(cell, for: id) { commit(id, cell) }
            }
    }
}

/// Derive the canvas height from the actual width proposed by the scroll view.
private struct CanvasExtent: Layout {
    let rows: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let height = CGFloat(rows) * CanvasLayout.columnPitch(for: width) - CanvasLayout.gap
        return CGSize(width: width, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
