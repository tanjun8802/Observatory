import Foundation
import Darwin

struct CodexError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
private struct ActiveCodexRun {
    static var runs: [UUID: ActiveCodexRun] = [:]
    let process: Process
    let directory: URL

    func stop() {
        // Foundation launches children in a separate process group on macOS.
        // npm launchers can start a second process that also needs to stop.
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if getpgid(pid) == pid { kill(-pid, SIGKILL) }
        else { kill(pid, SIGKILL) }
        process.waitUntilExit()
    }
}

struct CodexClient {
    var executable: URL?
    var timeout: Duration = .seconds(150)

    private func locate() throws -> URL {
        if let executable { return executable }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/codex" }
        let candidates = paths + [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CodexError("Install the Codex CLI and sign in with codex login, then try again.")
        }
        return URL(fileURLWithPath: path)
    }

    @MainActor static func shutdown() {
        for run in ActiveCodexRun.runs.values {
            run.stop()
            try? FileManager.default.removeItem(at: run.directory)
        }
        ActiveCodexRun.runs.removeAll()
    }

    @MainActor func answer(_ prompt: String, schema: String? = nil) async throws -> String {
        try await run(prompt, schema: schema, liveSearch: schema == nil).text
    }

    struct Result {
        let text: String
        let searchedWeb: Bool
    }

    @MainActor func run(_ prompt: String, schema: String?, liveSearch: Bool) async throws -> Result {
        try Task.checkCancellation()
        let binary = try locate()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: "observatory-codex-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let input = directory.appending(path: "prompt")
        let output = directory.appending(path: "answer")
        let log = directory.appending(path: "diagnostics")
        try Data(prompt.utf8).write(to: input)
        try Data().write(to: log)
        let stdin = try FileHandle(forReadingFrom: input)
        let stderr = try FileHandle(forWritingTo: log)
        defer { try? stdin.close(); try? stderr.close() }

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = directory
        var arguments = ["exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral",
                         "--sandbox", "read-only", "--disable", "shell_tool", "--disable", "apps",
                         "--disable", "plugins", "--disable", "multi_agent", "-c", "approval_policy=\"never\"",
                         "-c", liveSearch ? "web_search=\"live\"" : "web_search=\"disabled\"",
                         "-o", output.path]
        if let schema {
            let path = directory.appending(path: "schema.json")
            try Data(schema.utf8).write(to: path)
            arguments += ["--output-schema", path.path]
        }
        let events = directory.appending(path: "events.jsonl")
        var eventOutput: FileHandle?
        if schema != nil && liveSearch {
            try Data().write(to: events)
            eventOutput = try FileHandle(forWritingTo: events)
            arguments.append("--json")
        }
        defer { try? eventOutput?.close() }
        process.arguments = arguments + ["-"]
        process.standardInput = stdin
        process.standardOutput = eventOutput ?? FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let id = UUID()
        let run = ActiveCodexRun(process: process, directory: directory)
        ActiveCodexRun.runs[id] = run
        defer { ActiveCodexRun.runs.removeValue(forKey: id) }
        do {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw CodexError("Codex took too long to respond. Try again.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            run.stop()
            throw error
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let diagnostic = (try? String(contentsOf: log, encoding: .utf8))?.lowercased() ?? ""
            if ["401", "unauthorized", "not logged in", "refresh token"].contains(where: diagnostic.contains) {
                throw CodexError("Codex needs you to sign in again. Run codex login, then retry.")
            }
            if ["429", "usage limit", "rate limit"].contains(where: diagnostic.contains) {
                throw CodexError("Your Codex usage limit was reached. Try again after the limit resets.")
            }
            throw CodexError("Codex could not finish. Check your connection and Codex sign-in, then retry.")
        }
        let answer = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw CodexError("Codex returned an empty response. Try again.") }
        var searchedWeb = false
        if eventOutput != nil {
            for try await line in events.lines {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      event["type"] as? String == "item.completed",
                      let item = event["item"] as? [String: Any], item["type"] as? String == "web_search",
                      item["status"] as? String != "failed" else { continue }
                searchedWeb = true
                break
            }
        }
        return Result(text: answer, searchedWeb: searchedWeb)
    }
}
