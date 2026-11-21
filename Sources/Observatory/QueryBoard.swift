import SwiftUI

struct QueryBoard: View {
    private struct Answer {
        let question: String
        let reading: Reading
    }

    private let track: (String, Reading) -> Void
    @Environment(\.boardPalette) private var ink
    @State private var proposedFeed: FeedProposal?
    @State private var draftRequest = ""
    @State private var prompt = ""
    private let addFeed: (Monitor) -> Void
    @State private var answer: Answer?
    @State private var isExpanded = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    init(track: @escaping (String, Reading) -> Void, addFeed: @escaping (Monitor) -> Void) {
        self.addFeed = addFeed
        self.track = track
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(ink.secondary)
                    .accessibilityHidden(true)
                TextField("Ask a question or describe a feed…", text: $prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Question for Codex")
                if let task {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Asking Codex")
                    Button("Cancel") { task.cancel() }
                        .accessibilityLabel("Cancel question")
                } else {
                    Button("Ask Codex", action: submit)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error {
                Text(error).foregroundStyle(ink.coral).textSelection(.enabled)
            }
            if let answer {
                Divider()
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: answer.question).font(.subheadline.weight(.semibold))
                        FeedReadingView(reading: answer.reading, kind: .codex)
                        Button("Track this answer") { track(answer.question, answer.reading) }
                            .accessibilityHint("Opens a feed draft for this question and answer.")
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Text("Answer").font(.subheadline.weight(.medium))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
        .sheet(isPresented: Binding(get: { proposedFeed != nil }, set: { if !$0 { proposedFeed = nil } })) {
            if let draft = proposedFeed {
                ScheduledFeedSheet(draft: draft, editing: false, heading: "Create feed") { monitor in
                    addFeed(monitor)
                    if prompt == draftRequest { prompt = "" }
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func submit() {
        let submitted = prompt
        guard task == nil, !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        error = nil
        task = Task {
            defer { task = nil }
            do {
                let reply = try await DashboardQuery.submit(submitted)
                try Task.checkCancellation()
                switch reply {
                case .answer(let reading):
                    answer = Answer(question: submitted, reading: reading)
                    isExpanded = true
                    if prompt == submitted { prompt = "" }
                case .feed(let proposal):
                    draftRequest = submitted
                    proposedFeed = proposal
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
