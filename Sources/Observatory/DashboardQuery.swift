import Foundation

enum DashboardQuery {
    enum Result {
        case answer(Reading)
        case feed(FeedProposal)
    }

    static func submit(_ question: String, client: CodexClient = .init()) async throws -> Result {
        let instructions = """
            Respond to this Observatory dashboard user. If they ask you to set up a feed, widget, monitor or
            recurring dashboard update, return a feed proposal for them to review before saving. For questions
            about these features, and for ordinary questions, return a reading with the complete answer.

            When drafting a feed:
            \(FeedProposal.draftingInstructions)

            When answering a question:
            \(try CodexReading.readingInstructions)

            User request:
            \(question)
            """
        let schema = """
        {"type":"object","additionalProperties":false,"required":["result"],
         "properties":{"result":{"anyOf":[\(FeedProposal.schema),\(CodexReading.schema)]}}}
        """
        let reply = try await client.run(instructions, schema: schema, liveSearch: true)
        return try interpret(reply, question: question)
    }

    static func interpret(_ reply: CodexClient.Result, question: String) throws -> Result {
        guard let envelope = try? JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any],
              let result = envelope["result"] as? [String: Any] else {
            throw CodexError("Codex returned an unreadable dashboard response. Try again.")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        if result["cadence"] != nil {
            let proposal = try JSONDecoder().decode(FeedProposal.self, from: data)
            _ = try proposal.monitor()
            return .feed(proposal)
        }
        let message = CodexClient.Result(text: String(decoding: data, as: UTF8.self), searchedWeb: reply.searchedWeb)
        return .answer(try CodexReading.reading(from: message, scheduled: false, prompt: question))
    }
}
