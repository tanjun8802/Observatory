import Testing
@testable import Observatory

struct CodexFeedFormTests {
    @Test func editingIntervalUsesVisibleText() throws {
        let monitor = Monitor(kind: .codex, title: "Roundup", prompt: "Latest news?", schedule: .interval(minutes: 60))
        var form = CodexFeedForm(proposal: FeedProposal(editing: monitor))
        form.intervalText = "10x"
        do {
            _ = try form.monitor()
            Issue.record("Saving an invalid interval must leave the editor open.")
        } catch let issue as FormIssue {
            #expect(issue.input == .interval)
        }
        form.intervalText = "15"
        let updated = try form.monitor()
        #expect(updated.id == monitor.id)
        #expect(updated.schedule == .interval(minutes: 15))
    }

    @Test func trackingPreservesQuestionAndCompletedSchedulesRemainEditable() throws {
        let question = "Compare the updates.\nInclude dates."
        let tracked = try CodexFeedForm(proposal: FeedProposal(tracking: question)).monitor()
        #expect(tracked.prompt == question)
        let once = Monitor(kind: .codex, title: "Previous", prompt: question, schedule: .once(.distantPast))
        var form = CodexFeedForm(proposal: FeedProposal(editing: once))
        form.proposal?.title = "Renamed"
        let renamed = try form.monitor()
        #expect(renamed.id == once.id)
        #expect(renamed.title == "Renamed")
        #expect(renamed.schedule == once.schedule)
    }
}
