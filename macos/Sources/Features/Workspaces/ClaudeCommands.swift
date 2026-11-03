import Foundation

/// mostty: ⌘-click a command in Claude's output to open it in a new tab.
///
/// The screen can't tell a command from prose (Claude Code draws code blocks
/// as plain colored text, already wrapped and indented). So instead of
/// guessing from the screen, the clicked line is looked up in Claude Code's
/// saved conversation, where code blocks are marked with ``` fences. Only a
/// line that is part of a code block there counts as a command.
///
/// The same text can appear both in prose and in a command (e.g. a path), so
/// the clicked line is located in the reply using the lines around it on
/// screen, and only counts if that spot is inside a code block.
enum ClaudeCommands {
    /// How much of the end of the conversation file to search. Recent replies
    /// are what's on screen; this keeps big transcripts cheap.
    fileprivate static let tailBytes = 4 * 1024 * 1024

    /// How many screen rows above and below the click are used as context.
    static let contextRows = 6

    struct Match {
        /// The full command (unwrapped, unindented).
        let command: String
        /// The screen rows (indices into `rows`) the command is drawn on.
        let rows: ClosedRange<Int>
    }

    /// The command the screen row at `clicked` belongs to, or nil if it
    /// isn't part of one. `rows` are the screen rows around it.
    static func command(rows: [String], clicked: Int, sessionID: String) -> String? {
        match(rows: rows, clicked: clicked, sessionID: sessionID)?.command
    }

    static func match(rows: [String], clicked: Int, sessionID: String) -> Match? {
        guard rows.indices.contains(clicked) else { return nil }
        let needle = normalize(rows[clicked])
        guard needle.count >= 6,
              let replies = transcript(for: sessionID)?.update() else { return nil }

        // The clicked text can appear in several replies (e.g. quoted again
        // later). The spot whose surrounding lines match the screen best is
        // the one that was clicked; on a tie, the most recent reply.
        let normRows = rows.map(normalize)
        var best: (context: Int, answers: Set<String?>)?
        for reply in replies.reversed() {
            guard reply.stream.contains(needle),
                  let match = reply.bestMatch(rows: normRows, clicked: clicked) else { continue }
            if best == nil || match.context > best!.context { best = match }
        }
        guard let best, best.answers.count == 1, let found = best.answers.first,
              let command = found else { return nil }

        // Which neighboring rows are the rest of this (wrapped) command.
        let whole = normalize(command)
        var lo = clicked, hi = clicked
        while lo > 0, !normRows[lo - 1].isEmpty,
              whole.contains(normRows[(lo - 1)...hi].joined()) { lo -= 1 }
        while hi < normRows.count - 1, !normRows[hi + 1].isEmpty,
              whole.contains(normRows[lo...(hi + 1)].joined()) { hi += 1 }
        return Match(command: command, rows: lo...hi)
    }

    // MARK: Conversation files

    /// Parsed conversations, kept up to date by reading only what was
    /// appended since last time (Claude Code only ever appends), so lookups
    /// are fast enough to run while hovering.
    private static var transcripts: [String: Transcript] = [:]
    private static let lock = NSLock()

    private static func transcript(for sessionID: String) -> Transcript? {
        lock.lock(); defer { lock.unlock() }
        if let t = transcripts[sessionID] { return t }
        guard let url = WorkspaceNotifier.transcriptURL(for: sessionID) else { return nil }
        let t = Transcript(url: url)
        transcripts[sessionID] = t
        return t
    }

    private final class Transcript {
        let url: URL
        private var offset: UInt64 = 0
        private var partial = Data()
        private var replies: [Reply] = []

        init(url: URL) { self.url = url }

        /// All replies, after reading anything new in the file.
        func update() -> [Reply]? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < offset {
                // Rewritten: start over.
                offset = 0; partial = Data(); replies = []
            }
            guard size > offset else { return replies }

            var skipFirstLine = false
            if offset == 0, size > UInt64(ClaudeCommands.tailBytes) {
                // Only the end matters (it's what's on screen).
                offset = size - UInt64(ClaudeCommands.tailBytes)
                skipFirstLine = true
            }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd() else { return replies }
            offset += UInt64(data.count)

            var chunk = partial + data
            if skipFirstLine, let nl = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                chunk = chunk[(nl + 1)...]
            }
            var lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            partial = Data(lines.removeLast()) // incomplete last line (or empty)
            for line in lines {
                for text in ClaudeCommands.assistantTexts(inLine: Data(line)) {
                    replies.append(Reply(text))
                }
            }
            return replies
        }
    }

    /// Form used for matching. On screen, Claude's wrapping and indentation
    /// only add or move whitespace, and Markdown markers (`**`, backticks,
    /// `#`) are drawn as styling, so all of those are dropped on both sides.
    static func normalize(_ s: String) -> String {
        let dropped = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*`#●⎿"))
        return String(s.unicodeScalars.filter { !dropped.contains($0) })
    }

    /// The text parts of one conversation file line, if it's an assistant
    /// message.
    fileprivate static func assistantTexts(inLine line: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { part in
            part["type"] as? String == "text" ? part["text"] as? String : nil
        }
    }

    /// One reply, as a single normalized string made of units: each prose
    /// line, and each command of each code block, in order.
    private struct Reply {
        struct Unit {
            let range: Range<Int>
            let command: String? // nil for prose
        }

        private(set) var stream = ""
        private(set) var units: [Unit] = []
        private var chars: [Character] = []

        init(_ text: String) {
            var code: [Substring]?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    if let lines = code {
                        for command in Self.commands(in: lines) { add(command, command: command) }
                        code = nil
                    } else {
                        code = []
                    }
                } else if code != nil {
                    code?.append(line)
                } else {
                    add(String(line), command: nil)
                }
            }
            if let lines = code {
                for command in Self.commands(in: lines) { add(command, command: command) }
            }
            chars = Array(stream)
        }

        private mutating func add(_ text: String, command: String?) {
            let norm = ClaudeCommands.normalize(text)
            guard !norm.isEmpty else { return }
            let start = stream.count
            stream += norm
            units.append(.init(range: start..<(start + norm.count), command: command))
        }

        /// The commands in a code block: each non-empty line, with lines
        /// ending in a backslash joined to the next.
        private static func commands(in lines: [Substring]) -> [String] {
            var result: [String] = []
            var pending = ""
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasSuffix("\\") {
                    pending += line + "\n"
                    continue
                }
                let command = pending + line
                pending = ""
                if !command.isEmpty { result.append(command) }
            }
            if !pending.isEmpty { result.append(pending) }
            return result
        }

        /// The largest window of screen rows around the click found in this
        /// reply: how much text it covers, and what the clicked row is at
        /// each place it occurs (a command, or nil for prose). Windows can
        /// be one-sided, since the context may run past the start or end of
        /// this reply on screen.
        func bestMatch(rows: [String], clicked: Int) -> (context: Int, answers: Set<String?>)? {
            var best: (context: Int, answers: Set<String?>)?
            for k in 0...ClaudeCommands.contextRows {
                let spans = [
                    (max(0, clicked - k), min(rows.count - 1, clicked + k)),
                    (max(0, clicked - k), clicked),
                    (clicked, min(rows.count - 1, clicked + k)),
                ]
                for (lo, hi) in spans {
                    let window = rows[lo...hi].joined()
                    guard best == nil || window.count > best!.context else { continue }
                    let offset = rows[lo..<clicked].joined().count
                    let found = occurrences(of: window)
                    guard !found.isEmpty else { continue }
                    best = (window.count, Set(found.map { answer(at: $0 + offset) }))
                }
            }
            return best
        }

        /// The command of the unit at a stream position ("" for prose).
        private func answer(at position: Int) -> String? {
            units.first { $0.range.contains(position) }?.command
        }

        private func occurrences(of window: String) -> [Int] {
            let w = Array(window)
            guard !w.isEmpty, w.count <= chars.count else { return [] }
            var result: [Int] = []
            var i = 0
            while i + w.count <= chars.count {
                if chars[i] == w[0], Array(chars[i..<(i + w.count)]) == w { result.append(i) }
                i += 1
            }
            return result
        }
    }
}
