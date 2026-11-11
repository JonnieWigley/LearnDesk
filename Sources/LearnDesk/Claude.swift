import Foundation

struct ClaudeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct GeneratedCard: Decodable {
    let question: String
    let answer: String
}

struct GradeResult: Decodable {
    let score: Int
    let feedback: String
}

/// Writes questions and checks answers by running Claude Code (`claude -p`) on this Mac,
/// so it uses the Claude subscription Claude Code is signed in with. No API key involved.
enum Claude {
    /// Blank means whatever model Claude Code uses by default.
    static var model: String {
        (UserDefaults.standard.string(forKey: Prefs.model) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the `claude` command lives, or nil if it can't be found.
    static func locate() -> URL? {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        let custom = (UserDefaults.standard.string(forKey: Prefs.claudePath) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            candidates.append((custom as NSString).expandingTildeInPath)
        }
        candidates += [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? files.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted().reversed().map { "\(nvm)/\($0)/bin/claude" }
        }
        return candidates.first { files.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    // MARK: Tasks

    static func generateCards(topic: String, notes: String) async throws -> [GeneratedCard] {
        struct Output: Decodable { let cards: [GeneratedCard] }
        let system = """
        You write recall questions for a personal learning journal. The learner logs what they \
        studied; later they are quizzed on it without seeing their notes.

        Write 3 to 6 questions from the notes (fewer when the notes are short). Test understanding \
        of what the notes actually cover: prefer "why", "how", "what happens if" and short \
        read-this-code questions over trivia or definitions copied word for word. Each question \
        must stand on its own, since the notes will not be visible, and be answerable from memory \
        in a sentence or two or a few lines of code. Each answer is a concise model answer.

        If the notes contain a factual mistake, base the answer on what is correct and say so in \
        the answer. Write plain text; put code on its own lines.
        """
        let user = "Topic: \(topic)\n\nNotes:\n\(notes)"
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "cards": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string"],
                            "answer": ["type": "string"],
                        ],
                        "required": ["question", "answer"],
                        "additionalProperties": false,
                    ] as [String: Any],
                ] as [String: Any],
            ],
            "required": ["cards"],
            "additionalProperties": false,
        ]
        let output = try await request(Output.self, system: system, user: user, schema: schema)
        return output.cards
    }

    static func grade(card: Card, notes: String?, learnerAnswer: String) async throws -> GradeResult {
        let system = """
        You grade a learner's answer to a recall question from their own learning journal.

        Score it:
        0 = wrong, blank, or misses the main point
        1 = partly right, with a significant gap or error
        2 = correct in substance; minor omissions are fine
        3 = correct, complete and precise

        Judge the substance, not the wording, and accept correct answers that differ from the \
        model answer. Feedback is one to three sentences addressed to the learner: say exactly \
        what was wrong or missing, or confirm what was right. Be direct. No praise padding.
        """
        var user = "Topic: \(card.topic)\n\nQuestion:\n\(card.question)\n\nModel answer:\n\(card.answer)\n\n"
        if let notes, !notes.isEmpty {
            user += "The learner's original notes:\n\(notes)\n\n"
        }
        user += "Learner's answer:\n\(learnerAnswer)"
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "score": ["type": "integer"],
                "feedback": ["type": "string"],
            ],
            "required": ["score", "feedback"],
            "additionalProperties": false,
        ]
        return try await request(GradeResult.self, system: system, user: user, schema: schema)
    }

    // MARK: Running Claude Code

    private static func request<T: Decodable>(
        _ type: T.Type, system: String, user: String, schema: [String: Any]
    ) async throws -> T {
        guard let executable = locate() else {
            throw ClaudeError(message: "Claude Code wasn't found. Install it and sign in, or set its location in Settings.")
        }
        let schemaText = String(
            data: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
            encoding: .utf8
        ) ?? "{}"
        let prompt = user + "\n\nReply with only a JSON object matching this schema:\n" + schemaText

        var base = ["-p", "--output-format", "json", "--system-prompt", system]
        if !model.isEmpty {
            base += ["--model", model]
        }
        // No tools, nothing saved to Claude Code's history, no MCP servers.
        let strict = ["--json-schema", schemaText, "--tools", "", "--no-session-persistence", "--strict-mcp-config"]

        var output = try await run(executable, arguments: base + strict, input: prompt)
        if resultObject(in: output.stdout) == nil, output.stderr.contains("unknown option") {
            // An older Claude Code without those flags: ask plainly and parse the reply.
            output = try await run(executable, arguments: base, input: prompt)
        }

        guard let result = resultObject(in: output.stdout) else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudeError(message: "Claude Code gave no answer" + (detail.isEmpty ? "." : ": \(detail.prefix(300))"))
        }

        let text = result["result"] as? String ?? ""
        if result["is_error"] as? Bool == true {
            throw ClaudeError(message: explain(failure: text))
        }

        let decoder = JSONDecoder()
        if let structured = result["structured_output"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let value = try? decoder.decode(T.self, from: data) {
            return value
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let value = try? decoder.decode(T.self, from: Data(text[start...end].utf8)) {
            return value
        }
        throw ClaudeError(message: "Claude returned a response in an unexpected format.")
    }

    /// Claude Code prints one JSON object describing the result; find it.
    private static func resultObject(in stdout: String) -> [String: Any]? {
        for line in stdout.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix("{") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               object["type"] as? String == "result" {
                return object
            }
        }
        return nil
    }

    private static func explain(failure text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("limit") {
            return "You've reached your Claude usage limit, so quizzes are paused until it resets. (\(text))"
        }
        if lower.contains("login") || lower.contains("api key") || lower.contains("authenticat") {
            return "Claude Code isn't signed in. Open Terminal, run `claude`, and sign in with your Claude account."
        }
        return text.isEmpty ? "Claude Code reported an error." : "Claude Code reported an error: \(text)"
    }

    private static func run(_ executable: URL, arguments: [String], input: String) async throws
        -> (stdout: String, stderr: String)
    {
        // Claude Code inspects the git repository it starts in. Start it in an empty folder
        // outside the home folder, so it can never end up scanning a repository that covers
        // Music, Movies, Documents and so on (which makes macOS ask for access to all of them).
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LearnDesk-claude-code", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = workDir

                // Apps launched from Finder get a minimal PATH; add the usual places node lives.
                var environment = ProcessInfo.processInfo.environment
                let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
                environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
                // Make sure it bills the subscription, never a stray API key.
                environment.removeValue(forKey: "ANTHROPIC_API_KEY")
                environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
                // And stop git looking for a repository in any folder above the empty one.
                environment["GIT_CEILING_DIRECTORIES"] = workDir.deletingLastPathComponent().path
                process.environment = environment

                let stdin = Pipe()
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ClaudeError(message: "Couldn't start Claude Code: \(error.localizedDescription)"))
                    return
                }

                // Give up after three minutes rather than hang forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                    if process.isRunning { process.terminate() }
                }

                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()

                let errorReader = DispatchGroup()
                let errorBox = DataBox()
                errorReader.enter()
                DispatchQueue.global().async {
                    errorBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    errorReader.leave()
                }
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                errorReader.wait()
                process.waitUntilExit()

                continuation.resume(returning: (
                    String(data: out, encoding: .utf8) ?? "",
                    String(data: errorBox.data, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
