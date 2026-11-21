import SwiftUI

// The sheet owns these values so changing setup modes preserves the user's work.
struct CodexFeedForm {
    var request: String
    var proposal: FeedProposal?
    var intervalText: String

    init(request: String = "", proposal: FeedProposal? = nil) {
        self.request = request
        self.proposal = proposal
        if let proposal, proposal.cadence == .interval || proposal.minutes > 0 {
            intervalText = String(proposal.minutes)
        } else {
            intervalText = "60"
        }
    }

    func monitor() throws -> Monitor {
        guard var draft = proposal else { throw FormIssue(.request, "Describe your feed first.") }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FormIssue(.title, "Enter a feed name.")
        }
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FormIssue(.prompt, "Enter a prompt for each refresh.")
        }
        if draft.cadence == .interval {
            let text = intervalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let minutes = Int(text), (1...10080).contains(minutes) else {
                throw FormIssue(.interval, "Enter a whole number from 1 to 10,080 minutes.")
            }
            draft.minutes = minutes
        }
        do {
            return try draft.monitor()
        } catch {
            // FeedProposal preserves the original one-time date when editing a completed feed.
            let input: FeedInput = draft.cadence == .once ? .runAt : .dailyTime
            throw FormIssue(input, error.localizedDescription)
        }
    }
}

struct CodexFeedEditor: View {
    @Binding var form: CodexFeedForm
    let editing: Bool
    let canReturnToRequest: Bool
    let onSave: (Monitor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var job: Task<Void, Never>?
    private var focus = FeedFormFocus()

    init(form: Binding<CodexFeedForm>, editing: Bool = false, canReturnToRequest: Bool = false,
         onSave: @escaping (Monitor) -> Void) {
        _form = form
        self.editing = editing
        self.canReturnToRequest = canReturnToRequest
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let proposal = Binding($form.proposal) {
                LabeledContent("Feed name") {
                    TextField("Feed name", text: proposal.title).labelsHidden()
                        .feedInput(.title, value: proposal.wrappedValue.title, focus: focus)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Prompt for each refresh").accessibilityHidden(true)
                    TextField("Prompt for each refresh", text: proposal.prompt, axis: .vertical)
                        .lineLimit(3...6)
                        .labelsHidden()
                        .feedInput(.prompt, value: proposal.wrappedValue.prompt, focus: focus)
                }
                Picker("Schedule", selection: proposal.cadence) {
                    Text("On demand").tag(FeedCadence.manual)
                    Text("Repeat").tag(FeedCadence.interval)
                    Text("Daily").tag(FeedCadence.daily)
                    Text("Once").tag(FeedCadence.once)
                }
                .onChange(of: proposal.wrappedValue.cadence) { _, cadence in
                    focus.issue = nil
                    if cadence == .once && proposal.wrappedValue.runAt.isEmpty {
                        proposal.wrappedValue.runAt = ISO8601DateFormatter().string(from: .now.addingTimeInterval(3600))
                    }
                }
                if proposal.wrappedValue.cadence == .once {
                    DatePicker("Run at", selection: Binding(get: {
                        ISO8601DateFormatter().date(from: proposal.wrappedValue.runAt) ?? .now
                    }, set: { proposal.wrappedValue.runAt = ISO8601DateFormatter().string(from: $0) }),
                               in: (editing ? Date.distantPast : Date.now)..., displayedComponents: [.date, .hourAndMinute])
                        .feedInput(.runAt, value: proposal.wrappedValue.runAt, focus: focus)
                } else if proposal.wrappedValue.cadence == .interval {
                    HStack {
                        Text("Every")
                        TextField("Refresh interval in minutes", text: $form.intervalText)
                            .frame(width: 70)
                            .feedInput(.interval, value: form.intervalText, focus: focus)
                        Text("minutes")
                    }
                } else if proposal.wrappedValue.cadence == .daily {
                    let time = Binding<Date>(get: {
                        Calendar.current.date(bySettingHour: proposal.wrappedValue.hour,
                                              minute: proposal.wrappedValue.minute, second: 0, of: .now) ?? .now
                    }, set: {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                        proposal.wrappedValue.hour = parts.hour ?? 0
                        proposal.wrappedValue.minute = parts.minute ?? 0
                    })
                    DatePicker("Local time", selection: time, displayedComponents: .hourAndMinute)
                        .feedInput(.dailyTime, value: [proposal.wrappedValue.hour, proposal.wrappedValue.minute], focus: focus)
                }
                if proposal.wrappedValue.cadence != .manual {
                    Text("Scheduled feeds run while Observatory is open, including with its window closed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("What would you like to follow?").font(.headline)
                TextField("Every morning at 8, summarise the weather in London.", text: $form.request, axis: .vertical)
                    .lineLimit(3...6)
                    .disabled(job != nil)
                    .accessibilityLabel("Describe your feed and schedule")
                    .feedInput(.request, value: form.request, focus: focus)
            }
            if let issue = focus.issue { FormErrorText(message: issue.message).textSelection(.enabled) }
            Divider()
            HStack {
                if form.proposal != nil && canReturnToRequest {
                    Button("Back to request") {
                        form.proposal = nil
                        focus.issue = nil
                    }
                }
                if job != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Drafting feed")
                }
                Spacer()
                Button("Cancel") { job?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if form.proposal != nil {
                    Button(editing ? "Save changes" : "Add feed", action: save)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(job == nil ? "Draft feed" : "Drafting…", action: generate)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(form.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || job != nil)
                }
            }
        }
        .defaultFocus(focus.$keyboard, form.proposal == nil ? .request : .title)
        .onChange(of: form.proposal != nil) {
            let next: FeedInput = form.proposal == nil ? .request : .title
            focus.keyboard = next
            focus.accessibility = next
        }
        .onDisappear { job?.cancel() }
    }

    private func generate() {
        focus.issue = nil
        let request = form.request
        job = Task {
            do {
                let result = try await FeedProposal.suggest(request)
                try Task.checkCancellation()
                job = nil
                form = CodexFeedForm(request: request, proposal: result)
            } catch {
                job = nil
                guard !Task.isCancelled else { return }
                focus.report(FormIssue(.request, error.localizedDescription))
            }
        }
    }

    private func save() {
        do {
            onSave(try form.monitor())
            dismiss()
        } catch let issue as FormIssue {
            focus.report(issue)
        } catch {
            focus.report(FormIssue(.title, error.localizedDescription))
        }
    }
}
