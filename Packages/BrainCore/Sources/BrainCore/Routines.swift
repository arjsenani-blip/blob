import Foundation

// Routines: a named, ordered list of small steps ("Bedtime routine": shower, brush teeth, read, lights out)
// laid out on a timeline — counted forward from a start time, or backward from a "by" time.

public struct RoutineStep: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var minutes: Int
    /// The step's picture: an SF Symbol name and a color index, picked from the title (editable).
    public var symbol: String
    public var tint: Int

    public init(id: UUID = UUID(), title: String, minutes: Int, symbol: String? = nil, tint: Int? = nil) {
        self.id = id
        self.title = title
        self.minutes = max(1, minutes)
        let pick = RoutineIcons.pick(for: title)
        self.symbol = symbol ?? pick.symbol
        self.tint = tint ?? pick.tint
    }
}

public struct DailyRoutine: SyncRecord, Hashable {
    public enum Anchor: String, Codable, Sendable {
        /// `time` is when the first step starts.
        case start
        /// `time` is when the last step should be finished ("lights out at 10:30").
        case end
    }

    public var id: UUID
    public var name: String
    public var steps: [RoutineStep]
    public var anchor: Anchor
    /// Minutes after midnight.
    public var time: Int
    /// Calendar weekdays it runs on (1 = Sunday … 7 = Saturday). Empty = every day.
    public var weekdays: [Int]
    /// Remind me when it's time to start.
    public var remind: Bool
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), name: String, steps: [RoutineStep], anchor: Anchor = .start, time: Int = 21 * 60,
                weekdays: [Int] = [], remind: Bool = true, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.name = name
        self.steps = steps
        self.anchor = anchor
        self.time = time
        self.weekdays = weekdays
        self.remind = remind
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    public var totalMinutes: Int { steps.reduce(0) { $0 + $1.minutes } }
    public var startMinute: Int { anchor == .start ? time : time - totalMinutes }
    public var endMinute: Int { anchor == .start ? time + totalMinutes : time }

    public func runs(on day: Date, calendar: Calendar = .current) -> Bool {
        weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: day))
    }

    /// Each step with its start and end on a given day.
    public func timeline(on day: Date, calendar: Calendar = .current) -> [(step: RoutineStep, start: Date, end: Date)] {
        let base = calendar.startOfDay(for: day)
        var t = base.addingTimeInterval(Double(startMinute) * 60)
        return steps.map { s in
            let start = t
            t = t.addingTimeInterval(Double(s.minutes) * 60)
            return (s, start, t)
        }
    }
}

// MARK: - Understanding a routine you describe

public enum RoutineParser {
    /// "bedtime routine: shower 15 min, brush teeth, skincare, read 20 minutes, lights out at 10:30"
    /// "morning routine starting at 6:45 — wake up, make bed 2 min, shower, breakfast 15m, leave by 7:40"
    public static func parse(_ input: String) -> DailyRoutine {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // Name: "X routine" anywhere, else the part before a colon, else a guess from the time of day.
        var name = "My routine"
        if let r = lower.range(of: #"([a-z][a-z' -]{0,30}?)\s+routine"#, options: .regularExpression) {
            let raw = String(text[r]).trimmingCharacters(in: .whitespaces)
            let cleaned = raw.replacingOccurrences(of: #"^(my|a|the|new|make|create|add|set up|setup)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            name = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
            text = text.replacingCharacters(in: r, with: "")
        } else if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) < 32,
                  text[..<colon].range(of: #"\d"#, options: .regularExpression) == nil {
            name = String(text[..<colon]).trimmingCharacters(in: .whitespaces).capitalized
            text = String(text[text.index(after: colon)...])
        }

        // Anchor: "starting at 6:45" / "at 9pm" (start) vs "lights out at 10:30" / "in bed by 10:30" / "leave by 7:40" (end).
        var anchor: DailyRoutine.Anchor? = nil
        var time: Int? = nil
        let endPattern = #"(?:(?:lights out|in bed|asleep|sleep|leave(?: the house)?|out the door|done|finished|finish|be ready)\s+(?:at|by)|\bby)\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.)?)"#
        let startPattern = #"(?:start(?:ing|s)?(?: at)?|begin(?:ning|s)?(?: at)?|from|\bat)\s+(\d{1,2}(?::\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.)?)"#
        if let (m, range) = firstMatch(endPattern, in: text) {
            time = minutes(fromClock: m, isEvening: name.lowercased().contains("bed") || name.lowercased().contains("night") || name.lowercased().contains("even"))
            anchor = .end
            // "lights out at 10:30" is also a step of its own.
            let phrase = String(text[range]).lowercased()
            text = text.replacingCharacters(in: range, with: phrase.hasPrefix("lights out") ? "lights out 1 min" : "")
        } else if let (m, range) = firstMatch(startPattern, in: text) {
            time = minutes(fromClock: m, isEvening: name.lowercased().contains("bed") || name.lowercased().contains("night") || name.lowercased().contains("even"))
            anchor = .start
            text = text.replacingCharacters(in: range, with: "")
        }

        // Steps: split on commas, "then", "and then", "after that", new lines, semicolons, bullets.
        let parts = text
            .replacingOccurrences(of: #"(?i)\b(and then|then|after that|afterwards|next|finally)\b"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #"\s+and\s+(?=[a-z])"#, with: ",", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\.(\s+|$)"#, with: ",", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",;\n•–—"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-:*"))) }
            .filter { !$0.isEmpty }

        var steps: [RoutineStep] = []
        for p in parts {
            var title = p
            var mins: Int?
            if let (d, r) = firstMatch(#"(?:for\s+)?(?:about\s+|~)?(\d+(?:\.\d+)?|a|an|half an?)\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#, in: title) {
                mins = durationMinutes(d, String(title[r]))
                title.removeSubrange(r)
            }
            title = title.replacingOccurrences(of: #"^(i\s+|i'll\s+|to\s+|go\s+to\s+(?=bed))"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+(for|about)$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            guard title.count >= 2, title.range(of: #"[a-zA-Z]"#, options: .regularExpression) != nil else { continue }
            let pretty = title.prefix(1).uppercased() + title.dropFirst()
            steps.append(RoutineStep(title: pretty, minutes: mins ?? defaultMinutes(for: title)))
        }

        // No time given: mornings start at 7:00, bedtime ends at 10:30, otherwise start at 6:00 PM.
        let n = name.lowercased()
        if time == nil {
            if n.contains("morning") || n.contains("wake") { anchor = .start; time = 7 * 60 }
            else if n.contains("bed") || n.contains("night") || n.contains("sleep") { anchor = .end; time = 22 * 60 + 30 }
            else if n.contains("after school") || n.contains("afternoon") { anchor = .start; time = 15 * 60 + 30 }
            else { anchor = .start; time = 18 * 60 }
        }
        return DailyRoutine(name: name, steps: steps, anchor: anchor ?? .start, time: time ?? 18 * 60)
    }

    static func firstMatch(_ pattern: String, in s: String) -> (String, Range<String.Index>)? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let all = Range(m.range, in: s), let g = Range(m.range(at: 1), in: s) else { return nil }
        return (String(s[g]), all)
    }

    static func minutes(fromClock raw: String, isEvening: Bool) -> Int? {
        let s = raw.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
        let digits = s.filter { $0.isNumber || $0 == ":" }
        let parts = digits.split(separator: ":").compactMap { Int($0) }
        guard var h = parts.first, h <= 24 else { return nil }
        let m = parts.count > 1 ? parts[1] : 0
        if s.hasSuffix("pm"), h < 12 { h += 12 }
        else if s.hasSuffix("am"), h == 12 { h = 0 }
        else if !s.hasSuffix("am") && !s.hasSuffix("pm") {
            // No am/pm: evening routines and small hours mean PM ("lights out at 10:30" → 22:30).
            if isEvening && h < 12 { h += 12 } else if h >= 1 && h <= 5 { h += 12 }
        }
        return h * 60 + m
    }

    static func durationMinutes(_ n: String, _ phrase: String) -> Int {
        let v: Double
        switch n.lowercased() {
        case "a", "an": v = 1
        case "half a", "half an": v = 0.5
        default: v = Double(n) ?? 1
        }
        let hours = phrase.lowercased().range(of: #"\d*\s*(hours?|hrs?|h)\b"#, options: .regularExpression) != nil
            && phrase.lowercased().range(of: "min", options: .literal) == nil
        return max(1, Int((hours ? v * 60 : v).rounded()))
    }

    /// Typical lengths, so you only have to say the ones that differ.
    static func defaultMinutes(for title: String) -> Int {
        let t = title.lowercased()
        let table: [(String, Int)] = [
            ("lights out", 1), ("wake", 2), ("make bed", 3), ("make the bed", 3), ("brush", 3), ("floss", 2), ("teeth", 3),
            ("skincare", 5), ("skin care", 5), ("wash face", 3), ("face", 3), ("shower", 15), ("bath", 25), ("get dressed", 7),
            ("dress", 7), ("hair", 5), ("breakfast", 15), ("dinner", 30), ("lunch", 20), ("snack", 10), ("coffee", 5), ("tea", 5),
            ("water", 1), ("vitamin", 1), ("meds", 1), ("pill", 1), ("pack", 5), ("bag", 5), ("lunchbox", 5), ("plan", 5),
            ("journal", 10), ("gratitude", 5), ("meditat", 10), ("pray", 10), ("stretch", 10), ("yoga", 20), ("workout", 30),
            ("exercise", 30), ("run", 30), ("walk", 20), ("dog", 15), ("read", 20), ("homework", 60), ("study", 45),
            ("review", 20), ("tidy", 10), ("clean", 15), ("laundry", 10), ("dishes", 10), ("charge", 1), ("phone", 1),
            ("alarm", 1), ("pajama", 3), ("pjs", 3), ("change", 5), ("music", 15), ("practice", 30), ("commute", 20), ("drive", 20),
        ]
        return table.first { t.contains($0.0) }?.1 ?? 10
    }
}

// MARK: - The step pictures

/// Picks a minimalist picture (an SF Symbol in a soft colored circle) for a step from what it says.
public enum RoutineIcons {
    /// Palette indexes; the app maps them to soft pastel fills with a deeper glyph color.
    public static let tintCount = 8

    public static let table: [(keys: [String], symbol: String)] = [
        (["lights out", "sleep", "bed", "nap"], "moon.zzz.fill"),
        (["wake", "alarm", "get up"], "alarm.fill"),
        (["brush", "teeth", "floss"], "mouth.fill"),
        (["shower"], "shower.fill"),
        (["bath"], "bathtub.fill"),
        (["skincare", "skin care", "face", "moistur", "lotion"], "drop.fill"),
        (["hair"], "comb.fill"),
        (["dress", "clothes", "outfit", "pajama", "pjs", "change"], "tshirt.fill"),
        (["breakfast", "lunch", "dinner", "eat", "meal", "snack", "cook"], "fork.knife"),
        (["coffee", "tea"], "cup.and.saucer.fill"),
        (["water", "drink", "hydrat"], "waterbottle.fill"),
        (["vitamin", "meds", "medicine", "pill"], "pills.fill"),
        (["pack", "bag", "backpack"], "backpack.fill"),
        (["read", "book"], "book.fill"),
        (["journal", "write", "gratitude", "plan"], "pencil.and.scribble"),
        (["meditat", "breath", "pray", "mindful"], "brain.head.profile"),
        (["stretch", "yoga"], "figure.flexibility"),
        (["workout", "exercise", "gym", "lift"], "dumbbell.fill"),
        (["run", "jog"], "figure.run"),
        (["walk", "dog"], "figure.walk"),
        (["homework", "study", "review", "assignment", "flashcard"], "graduationcap.fill"),
        (["tidy", "clean", "dishes", "laundry", "make bed", "make the bed"], "sparkles"),
        (["phone", "charge", "screen"], "iphone.gen3.slash"),
        (["music", "piano", "guitar", "practice"], "music.note"),
        (["drive", "commute", "leave", "bus", "car"], "car.fill"),
        (["sun", "outside", "fresh air"], "sun.max.fill"),
        (["call", "text", "family", "friend"], "phone.fill"),
        (["pet", "cat", "feed"], "pawprint.fill"),
    ]

    public static func pick(for title: String) -> (symbol: String, tint: Int) {
        let t = title.lowercased()
        // Longest key first so "make bed" beats "bed".
        let hits = table.flatMap { row in row.keys.map { ($0, row.symbol) } }.filter { t.contains($0.0) }
        let symbol = hits.max { $0.0.count < $1.0.count }?.1 ?? "circle.hexagongrid.fill"
        // A stable color per picture, so the same kind of step always looks the same.
        let seed = symbol.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return (symbol, abs(seed) % tintCount)
    }
}
