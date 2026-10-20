import Foundation

/// A sentence about work you've done — "worked 45 min on the history essay", "finished the outline",
/// "got 92/100 on the chem lab" — as opposed to something new to add. Runs on-device.
public enum LogIntent: Equatable, Sendable {
    /// Time spent. `query` names the assignment (may be empty: "worked for an hour").
    case worked(minutes: Int, query: String, note: String?)
    /// One step of an assignment is done ("finished the outline for my english essay").
    case finishedStep(step: String, query: String)
    /// The whole thing is done / turned in.
    case completed(query: String)
    case started(query: String)
    case progress(percent: Int, query: String)
    case grade(earned: Double, possible: Double, query: String)
    /// "Break the history project into steps".
    case planSteps(query: String)
}

public struct ProgressLogParser {
    public init() {}

    public func parse(_ input: String) -> LogIntent? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        // "log 30 minutes on …" — the word "log" means the verb can be left out.
        let saidLog = text.range(of: #"^(hey |ok |okay )?(blob,?\s*)?(please |can you |could you )?(log|add|track)\s+\d"#, options: [.regularExpression, .caseInsensitive]) != nil
        text = text.replacingOccurrences(of: #"^(hey |ok |okay )?(blob,?\s*)?(please |can you |could you )?(log( that)?:?\s+|track\s+|mark( that)?\s+|note( that)?\s+)?"#,
                                         with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"^(i('ve| have)?|i just|just)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        let lower = text.lowercased()
        // Something with a due date is a new to-do, not a log ("finish the essay by friday").
        if lower.range(of: #"\b(due|by (mon|tue|wed|thu|fri|sat|sun|tomorrow|next|tonight)|tomorrow|tonight|next week)\b"#, options: .regularExpression) != nil,
           lower.range(of: #"^(got|scored|received|worked|spent|did|studied)\b"#, options: .regularExpression) == nil {
            return nil
        }

        if let g = grade(lower) { return g }

        // "break X into steps", "plan out X", "make a plan for X"
        if let m = groups(#"^(break|split)\s+(up\s+)?(.+?)\s+(up\s+)?into\s+(steps|parts|milestones|chunks)$"#, lower) { return .planSteps(query: clean(m[3])) }
        if let m = groups(#"^(plan out|make a plan for|make steps for|set up milestones for)\s+(.+)$"#, lower) { return .planSteps(query: clean(m[2])) }

        // Time spent: "worked 45 min on X", "spent 2 hours on X", "did an hour of X", "studied for 30 minutes for the bio test"
        if let w = worked(lower) ?? (saidLog ? worked("worked " + lower) : nil) { return w }

        // Percent: "X is 50% done", "I'm halfway through X", "50% done with X"
        if let m = groups(#"^(?:i'?m |i am )?(halfway|half way|mostly|almost|nearly)\s+(?:done with|through|finished with)\s+(.+)$"#, lower) {
            return .progress(percent: m[1].hasPrefix("half") ? 50 : 85, query: clean(m[2]))
        }
        if let m = groups(#"^(.+?)\s+is\s+(\d{1,3})\s*%\s*(done|finished|complete)?$"#, lower), let p = Int(m[2]) { return .progress(percent: min(p, 100), query: clean(m[1])) }
        if let m = groups(#"^(?:i'?m |i am )?(\d{1,3})\s*%\s*(?:done|through|finished)\s+(?:with\s+)?(.+)$"#, lower), let p = Int(m[1]) { return .progress(percent: min(p, 100), query: clean(m[2])) }

        // Steps: "finished the outline for X", "done with the rough draft of X"
        let doneVerb = #"(finished|completed|wrapped up|done with|did|knocked out)"#
        if let m = groups("^\(doneVerb)\\s+(?:the\\s+|my\\s+)?(.+?)\\s+(?:for|of|on|in)\\s+(?:the\\s+|my\\s+)?(.+)$", lower),
           Self.isStepWord(m[2]) {
            return .finishedStep(step: clean(m[2]), query: clean(m[3]))
        }

        // Whole assignment: "finished X", "turned in X", "submitted X", "X is done"
        if let m = groups(#"^(finished|completed|turned in|submitted|handed in|done with|wrapped up)\s+(.+)$"#, lower) { return .completed(query: clean(m[2])) }
        if let m = groups(#"^(.+?)\s+is\s+(done|finished|complete|turned in|submitted)$"#, lower) { return .completed(query: clean(m[1])) }
        if let m = groups(#"^(started|began|starting|kicked off)\s+(on\s+|working on\s+)?(.+)$"#, lower) { return .started(query: clean(m[3])) }
        return nil
    }

    private func grade(_ s: String) -> LogIntent? {
        let verb = #"(?:got|scored|received|earned|get)\s+(?:an?\s+)?"#
        // 92/100, 18 out of 20, 92 percent, 92%, A-
        if let m = groups("^\(verb)(\\d+(?:\\.\\d+)?)\\s*(?:/|out of)\\s*(\\d+(?:\\.\\d+)?)\\s+(?:on|in|for)\\s+(.+)$", s),
           let e = Double(m[1]), let p = Double(m[2]), p > 0 {
            return .grade(earned: e, possible: p, query: clean(m[3]))
        }
        if let m = groups("^\(verb)(\\d+(?:\\.\\d+)?)\\s*(?:%|percent)?\\s+(?:on|in|for)\\s+(.+)$", s), let e = Double(m[1]), e <= 110 {
            return .grade(earned: e, possible: 100, query: clean(m[2]))
        }
        if let m = groups("^\(verb)([abcdf][+-]?)\\s+(?:on|in|for)\\s+(.+)$", s) {
            return .grade(earned: Self.letterPercent(m[1]), possible: 100, query: clean(m[2]))
        }
        return nil
    }

    private func worked(_ s: String) -> LogIntent? {
        let amount = #"(\d+(?:\.\d+)?|an?|half an?|one|two|three|four|five|a couple of)\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#
        let pattern = "^(?:worked|spent|did|studied|put in|been working)\\s+(?:on\\s+(.+?)\\s+for\\s+)?(?:for\\s+)?(?:about\\s+|like\\s+|around\\s+)?\(amount)(?:\\s+(?:on|of|for|doing|working on|studying(?: for)?)\\s+(.+))?$"
        guard let m = groups(pattern, s) else { return nil }
        guard let mins = Self.minutes(m[2], m[3]) else { return nil }
        var query = m[1].isEmpty ? m[4] : m[1]
        var note: String?
        // "… on the essay — wrote the intro"
        if let r = query.range(of: #"\s*(—|-|:|,)\s+"#, options: .regularExpression) {
            note = String(query[r.upperBound...])
            query = String(query[..<r.lowerBound])
        }
        return .worked(minutes: mins, query: clean(query), note: note)
    }

    static func minutes(_ n: String, _ unit: String) -> Int? {
        let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "half a": 0.5, "half an": 0.5, "a couple of": 2]
        guard let value = Double(n) ?? words[n] else { return nil }
        let isHours = unit.hasPrefix("h")
        let mins = Int((isHours ? value * 60 : value).rounded())
        return mins > 0 && mins <= 16 * 60 ? mins : nil
    }

    static func letterPercent(_ l: String) -> Double {
        let base: [Character: Double] = ["a": 95, "b": 85, "c": 75, "d": 65, "f": 50]
        var v = base[l.first ?? "f"] ?? 50
        if l.hasSuffix("+") { v += 3 } else if l.hasSuffix("-") { v -= 3 }
        return v
    }

    static let stepWords = ["outline", "draft", "rough draft", "final draft", "intro", "introduction", "conclusion", "research", "sources",
                            "bibliography", "works cited", "thesis", "slides", "study guide", "practice test", "review", "notes", "annotations",
                            "data", "analysis", "graphs", "write up", "write-up", "first part", "part 1", "part 2", "part one", "part two",
                            "first half", "second half", "reading", "body paragraph", "paragraph", "plan", "script", "poster", "edit", "editing", "revisions", "revise"]
    static func isStepWord(_ s: String) -> Bool {
        stepWords.contains { s == $0 || s.hasPrefix($0 + " ") || s.hasSuffix(" " + $0) || s.contains($0) && s.split(separator: " ").count <= 3 }
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"^(the|my|on|for|with)\s+"#, with: "", options: [.regularExpression])
            .replacingOccurrences(of: #"\s+(today|tonight|just now|already|so far)$"#, with: "", options: [.regularExpression])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whole-string regex match → capture groups ("" for groups that didn't take part).
    private func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}

// MARK: - Finding which assignment you meant

public enum TaskMatcher {
    static let stop: Set<String> = ["the", "my", "a", "an", "on", "for", "of", "in", "to", "and", "assignment", "homework", "hw", "class", "that", "this", "it"]
    static let aliases: [String: [String]] = [
        "chem": ["chemistry"], "bio": ["biology"], "calc": ["calculus"], "precalc": ["precalculus"], "lang": ["language"],
        "lit": ["literature"], "gov": ["government"], "econ": ["economics"], "psych": ["psychology"], "hist": ["history"],
        "apush": ["history", "us"], "eng": ["english"], "sci": ["science"], "cs": ["computer", "science"], "pset": ["problem", "set"],
        "paper": ["essay"], "essay": ["paper"], "test": ["exam"], "exam": ["test"],
    ]

    public static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !stop.contains($0) }
    }

    /// Best match for what you said, or nil when nothing fits. An empty query means "what I'm working on now",
    /// so it picks `fallback` (e.g. the block running in the timeline) or the soonest-due open assignment.
    public static func best(_ query: String, in tasks: [BrainTask], fallback: UUID? = nil, now: Date = Date()) -> BrainTask? {
        let live = tasks.filter { !$0.deleted }
        let q = words(query)
        if q.isEmpty {
            if let f = fallback, let t = live.first(where: { $0.id == f }) { return t }
            return live.filter { !$0.isCompleted }.min { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        }
        var bestScore = 0.0
        var best: BrainTask?
        for t in live {
            let hay = Set(words(t.title + " " + (t.course ?? "")) + words(t.title + " " + (t.course ?? "")).flatMap { aliases[$0] ?? [] })
            var score = 0.0
            for w in q {
                if hay.contains(w) { score += 1 }
                else if (aliases[w] ?? []).contains(where: hay.contains) { score += 0.9 }
                else if w.count >= 4, hay.contains(where: { $0.hasPrefix(w) || w.hasPrefix($0) && $0.count >= 4 }) { score += 0.7 }
            }
            guard score > 0 else { continue }
            score /= Double(q.count)
            // Prefer open work and things due soon.
            if !t.isCompleted { score += 0.15 }
            if let d = t.due { score += max(0, 0.1 - abs(d.timeIntervalSince(now)) / (86_400 * 300)) }
            if score > bestScore { bestScore = score; best = t }
        }
        return bestScore >= 0.5 ? best : nil
    }

    public static func step(_ query: String, in task: BrainTask) -> Milestone? {
        let q = words(query)
        guard !q.isEmpty else { return task.nextMilestone }
        return task.milestones.max { a, b in overlap(q, a.title) < overlap(q, b.title) }.flatMap { overlap(q, $0.title) > 0 ? $0 : nil }
    }

    public static func overlap(_ q: [String], _ title: String) -> Double {
        let t = Set(words(title))
        return Double(q.filter { w in t.contains(w) || t.contains { $0.hasPrefix(w) || w.hasPrefix($0) } }.count)
    }
}

// MARK: - Big assignments

extension MilestonePlanner {
    /// Rough whole-assignment estimate for something big when you didn't say how long it takes.
    public static func defaultEstimate(title: String) -> Int? {
        let t = title.lowercased()
        func has(_ w: String...) -> Bool { w.contains { t.contains($0) } }
        if has("science fair", "final project", "portfolio", "research paper", "thesis") { return 600 }
        if has("project", "presentation") { return 360 }
        if has("essay", "paper", "report", "dbq") { return 300 }
        if has("final", "midterm", "exam", "ap test") { return 360 }
        if has("study for", "test") { return 180 }
        if has("book", "novel") { return 300 }
        if has("lab report") { return 180 }
        return nil
    }

    /// Should a newly added assignment be tracked long-term with steps?
    public static func looksLongTerm(title: String, due: Date?, now: Date = Date(), explicit: Bool = false) -> Bool {
        if explicit { return true }
        guard let due, due.timeIntervalSince(now) >= 4 * 86_400 else { return false }
        return defaultEstimate(title: title) != nil
    }
}
