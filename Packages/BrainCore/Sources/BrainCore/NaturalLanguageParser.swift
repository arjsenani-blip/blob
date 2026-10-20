import Foundation

/// What a quick-add sentence turned into.
public struct ParsedEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case event, task }

    public var kind: Kind
    public var title: String
    /// Event start, or the task's due date.
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool
    public var hasExplicitTime: Bool
    public var location: String?
    public var tag: String?
    public var recurrence: RecurrenceRule
    /// Event length, or task estimate.
    public var durationMinutes: Int?
    public var priority: BrainTask.Priority
    /// The class it belongs to, when the text mentions one ("AP Lang essay due fri" → "AP Lang").
    public var course: String? = nil
}

/// Turns things like "soccer every tue 5-7pm at Field 3" or "essay due fri" into an event or a task.
/// Runs fully on-device; no network or API key needed.
public struct NaturalLanguageParser {
    public var calendar: Calendar
    public var now: Date
    /// The user's class names (from Classroom and existing assignments), used to recognize school work.
    public var courses: [String]

    public init(calendar: Calendar = .current, now: Date = Date(), courses: [String] = []) {
        self.calendar = calendar
        self.now = now
        self.courses = courses
    }

    // MARK: Assignment vs. event

    /// Words that mean "school work with a due date", not "something happening at a time".
    static let assignmentPattern = #"\b(home ?work|hw|assignment|essay|worksheet|problem ?set|pset|practice (problems|questions|set|test)|lab (report|write ?up)|write ?up|project|reading|read (ch|chapter|pages|pp)|chapters?|paper|report|study ?guide|study for|review for|notes|outline|rough draft|final draft|draft|annotations?|exercises|packet|journal|reflection|flashcards|vocab (list|cards|words)|discussion post|turn in|submit|finish|complete|do (the|my)|frq|dbq|leq|saq|lab\b)"#

    /// Words that mean an actual event at a time or place.
    static let eventPattern = #"\b(practice|game|match|meet|meeting|appointment|appt|dentist|doctor|orthodontist|party|class|club|rehearsal|concert|recital|tryouts?|lesson|dinner|lunch|breakfast|movie|trip|flight|interview|tournament|session|test|exam|quiz|midterm|finals?(?!\s*draft)|ap exam|ceremony|assembly|conference|shift|work)\b"#

    /// Common subject words → used to fill in the course when no known class name matches.
    static let subjects: [(pattern: String, name: String)] = [
        (#"\b(ap )?calc(ulus)?\b"#, "Calculus"), (#"\b(pre-?calc|precalculus)\b"#, "Precalculus"), (#"\b(math|algebra|geometry|stats|statistics)\b"#, "Math"),
        (#"\b(chem|chemistry)\b"#, "Chemistry"), (#"\b(bio|biology)\b"#, "Biology"), (#"\bphysics\b"#, "Physics"),
        (#"\b(ap )?lang\b"#, "AP Lang"), (#"\b(ap )?lit\b"#, "AP Lit"), (#"\benglish\b"#, "English"),
        (#"\b(apush|us history)\b"#, "APUSH"), (#"\b(world history|history)\b"#, "History"), (#"\b(gov|government|civics)\b"#, "Government"),
        (#"\b(econ|economics)\b"#, "Economics"), (#"\b(psych|psychology)\b"#, "Psychology"), (#"\bspanish\b"#, "Spanish"), (#"\bfrench\b"#, "French"),
        (#"\b(cs|computer science|apcsa|csp)\b"#, "Computer Science"),
    ]

    func detectCourse(_ text: String) -> String? {
        let lower = text.lowercased()
        // Longest known class name first ("AP Calculus BC" before "Calculus").
        for c in courses.sorted(by: { $0.count > $1.count }) where !c.isEmpty {
            if lower.contains(c.lowercased()) { return c }
            // Also match the class name's distinctive first word(s), e.g. "chemistry" for "Chemistry Honors (P3)".
            let core = c.lowercased().components(separatedBy: CharacterSet(charactersIn: "(-–:|")).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if core.count >= 4, lower.contains(core) { return c }
        }
        for s in Self.subjects where lower.range(of: s.pattern, options: .regularExpression) != nil {
            // Prefer the user's own class that contains this subject.
            return courses.first { $0.lowercased().contains(s.name.lowercased()) } ?? s.name
        }
        return nil
    }

    private typealias HM = (hour: Int, minute: Int)

    // MARK: Regex plumbing

    /// Finds the first match that passes `validate`, removes it from `text`, and returns its capture groups (lowercased; nil when a group didn't take part).
    private func take(_ pattern: String, from text: inout String, caseSensitive: Bool = false,
                      validate: ([String?]) -> Bool = { _ in true }) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else {
            assertionFailure("Bad pattern: \(pattern)")
            return nil
        }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var groups: [String?] = []
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            let lowered = groups.map { $0?.lowercased() }
            guard validate(lowered) else { continue }
            text = ns.replacingCharacters(in: match.range, with: " ")
            return caseSensitive ? groups : lowered
        }
        return nil
    }

    private func contains(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Vocabulary

    private static let weekdayPattern = "monday|mon|tuesday|tues|tue|wednesday|weds|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun"
    private static let monthPattern = "january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec"
    private static let timePattern = #"(?:(\d{1,2})(?::(\d{2}))?\s*(a\.m\.|p\.m\.|am|pm|a|p)?|(noon|midnight))"#

    private func weekdayNumber(_ word: String) -> Int? {
        let w = word.lowercased()
        let table: [(String, Int)] = [("sun", 1), ("mon", 2), ("tue", 3), ("wed", 4), ("thu", 5), ("fri", 6), ("sat", 7)]
        return table.first { w.hasPrefix($0.0) }?.1
    }

    private func monthNumber(_ word: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex { word.lowercased().hasPrefix($0) }.map { $0 + 1 }
    }

    private func number(_ word: String) -> Double? {
        let w = word.lowercased().trimmingCharacters(in: .whitespaces)
        if let d = Double(w) { return d }
        switch w {
        case "a", "an", "one": return 1
        case "two", "a couple of", "couple of": return 2
        case "three", "a few", "few": return 3
        case "four": return 4
        case "five": return 5
        case "half a", "half an": return 0.5
        default: return nil
        }
    }

    private func minutes(amount: Double, unit: String) -> Int {
        let u = unit.lowercased()
        if u.hasPrefix("h") { return Int((amount * 60).rounded()) }
        if u.hasPrefix("d") { return Int(amount * 1440) }
        if u.hasPrefix("w") { return Int(amount * 10080) }
        return Int(amount.rounded())
    }

    // MARK: Parse

    public func parse(_ input: String) -> ParsedEntry {
        var text = " " + input.replacingOccurrences(of: "\n", with: " ") + " "
        let lowerInput = input.lowercased()
        let looksLikeAssignment = lowerInput.range(of: Self.assignmentPattern, options: .regularExpression) != nil
        let looksLikeEvent = lowerInput.range(of: Self.eventPattern, options: .regularExpression) != nil
            && !(lowerInput.range(of: #"\b(study|review) for\b"#, options: .regularExpression) != nil)
        let today = calendar.startOfDay(for: now)

        var forcedTask = false
        var tag: String?
        var priority: BrainTask.Priority = .normal
        var recurrence = RecurrenceRule.none
        var relativeStart: Date?
        var relativeHasTime = false
        var duration: Int?
        var day: Date?
        var startTime: HM?
        var endTime: HM?
        var startHadMeridiem = false
        var endHadMeridiem = false
        var timeHint: HM?
        var dayIsBareWeekday = false

        let eveningContext = contains(#"\b(tonight|evening|night|dinner|pm)\b"#, in: text)

        // Tag and priority
        if let g = take(#"(?<=\s)#([\p{L}\p{N}_-]+)"#, from: &text, caseSensitive: true) { tag = g[1] }
        if take(#"(?<=\s)(!{1,3}|!high|!urgent)(?=\s)"#, from: &text) != nil { priority = .high }
        if take(#"(?<=\s)(!low)(?=\s)"#, from: &text) != nil { priority = .low }

        // Explicit task markers
        if take(#"^\s*(todo:?|to-do:?|task:|remind me to|reminder:|hw:)\s"#, from: &text) != nil { forcedTask = true }
        if take(#"\sdue(\s+(on|by|at))?(?=\s)"#, from: &text) != nil { forcedTask = true }
        if contains(#"\sby\s+(today|tonight|tomorrow|tmrw|next|this|"# + Self.weekdayPattern + "|" + Self.monthPattern + #"|\d)"#, in: text) {
            forcedTask = true
        }

        // Recurrence
        if take(#"\b(every\s?day|daily|each day)\b"#, from: &text) != nil {
            recurrence = RecurrenceRule(frequency: .daily)
        } else if take(#"\b(on\s+)?(every\s+weekday|weekdays)\b"#, from: &text) != nil {
            recurrence = RecurrenceRule(frequency: .weekdays)
        } else if let g = take(#"\bevery\s+((?:(?:"# + Self.weekdayPattern + #")(?:day)?s?\.?(?:\s*(?:,|and|&|/)\s*)?)+)"#, from: &text) {
            let days = (g[1] ?? "").components(separatedBy: CharacterSet.letters.inverted).compactMap { $0.isEmpty ? nil : weekdayNumber($0) }
            recurrence = RecurrenceRule(frequency: .weekly, weekdays: Array(Set(days)).sorted())
        } else if let g = take(#"\b(?:on\s+)?(mondays|tuesdays|wednesdays|thursdays|fridays|saturdays|sundays)\b"#, from: &text) {
            recurrence = RecurrenceRule(frequency: .weekly, weekdays: [weekdayNumber(g[1] ?? "")].compactMap { $0 })
        } else if take(#"\b(every\s+week|weekly)\b"#, from: &text) != nil {
            recurrence = RecurrenceRule(frequency: .weekly)
        } else if take(#"\b(every\s+month|monthly)\b"#, from: &text) != nil {
            recurrence = RecurrenceRule(frequency: .monthly)
        }

        // "in 20 minutes", "in 3 days"
        if let g = take(#"\bin\s+(\d+(?:\.\d+)?|an?|one|two|three|a\s+couple\s+of|a\s+few)\s+(minutes?|mins?|hours?|hrs?|days?|weeks?)\b"#, from: &text),
           let amount = number(g[1] ?? "") {
            let unit = g[2] ?? "m"
            let mins = minutes(amount: amount, unit: unit)
            relativeStart = now.addingTimeInterval(Double(mins) * 60)
            relativeHasTime = unit.hasPrefix("m") || unit.hasPrefix("h")
        }

        // Durations: "for 2 hours", "for 1h30m", "~45m", "90 min long"
        if let g = take(#"\bfor\s+(\d+)\s*h(?:ours?|rs?)?\s*(\d+)\s*m(?:in(?:ute)?s?)?\b"#, from: &text) {
            duration = Int(g[1] ?? "0")! * 60 + Int(g[2] ?? "0")!
        } else if let g = take(#"\bfor\s+(\d+(?:\.\d+)?|an?|one|two|three|half\s+an?)\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#, from: &text),
                  let amount = number(g[1] ?? "") {
            duration = minutes(amount: amount, unit: g[2] ?? "m")
        } else if let g = take(#"(?<=\s)~\s*(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#, from: &text),
                  let amount = number(g[1] ?? "") {
            duration = minutes(amount: amount, unit: g[2] ?? "m")
        } else if let g = take(#"\b(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?)\s+long\b"#, from: &text),
                  let amount = number(g[1] ?? "") {
            duration = minutes(amount: amount, unit: g[2] ?? "m")
        }

        // Dates
        let lead = #"(?:(?:on|by)\s+)?"#
        if take(#"\b"# + lead + #"(the\s+)?day\s+after\s+tomorrow\b"#, from: &text) != nil {
            day = calendar.date(byAdding: .day, value: 2, to: today)
        } else if take(#"\b"# + lead + #"(tomorrow|tmrw|tmr|tmw|tomorow|tommorow|tommorrow)\b"#, from: &text) != nil {
            day = calendar.date(byAdding: .day, value: 1, to: today)
        } else if take(#"\b"# + lead + #"(today|tdy)\b"#, from: &text) != nil {
            day = today
        } else if take(#"\b"# + lead + #"next\s+week\b"#, from: &text) != nil {
            day = nextWeekday(2, includeToday: false).flatMap { d in isInCurrentWeek(d) ? calendar.date(byAdding: .day, value: 7, to: d) : d }
        } else if take(#"\b"# + lead + #"(this\s+)?weekend\b"#, from: &text) != nil {
            day = nextWeekday(7, includeToday: true)
        } else if take(#"\b"# + lead + #"next\s+month\b"#, from: &text) != nil {
            let comps = calendar.dateComponents([.year, .month], from: today)
            day = calendar.date(byAdding: .month, value: 1, to: calendar.date(from: comps)!)
        } else if let g = take(#"\b"# + lead + #"("# + Self.monthPattern + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#, from: &text) {
            day = makeDate(month: monthNumber(g[1] ?? ""), day: Int(g[2] ?? ""), year: g[3].flatMap { Int($0) })
        } else if let g = take(#"\b"# + lead + #"(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("# + Self.monthPattern + #")\b(?:,?\s+(\d{4}))?"#, from: &text) {
            day = makeDate(month: monthNumber(g[2] ?? ""), day: Int(g[1] ?? ""), year: g[3].flatMap { Int($0) })
        } else if let g = take(#"(?<![\d/])"# + lead + #"(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?![\d/])"#, from: &text) {
            var year = g[3].flatMap { Int($0) }
            if let y = year, y < 100 { year = 2000 + y }
            day = makeDate(month: Int(g[1] ?? ""), day: Int(g[2] ?? ""), year: year)
        } else if let g = take(#"\b"# + lead + #"(next|this)?\s*("# + Self.weekdayPattern + #")\b\.?(?=(\s+(?:at\s+)?\d)?)"#, from: &text, validate: { g in
            // "sat"/"sun"/"wed" are also normal words, so only accept them with a qualifier or full name.
            let word = g[2] ?? ""
            let ambiguous = ["sat", "sun", "wed"].contains(word)
            return !ambiguous || g[1] != nil || g[0]?.contains("on ") == true || g[0]?.contains("by ") == true || g[3] != nil
        }) {
            if let wd = weekdayNumber(g[2] ?? "") {
                if g[1] == "next" {
                    day = nextWeekday(wd, includeToday: false).flatMap { d in isInCurrentWeek(d) ? calendar.date(byAdding: .day, value: 7, to: d) : d }
                } else {
                    day = nextWeekday(wd, includeToday: true)
                    dayIsBareWeekday = true
                }
            }
        } else if let g = take(#"\b"# + lead + #"the\s+(\d{1,2})(?:st|nd|rd|th)\b"#, from: &text), let d = Int(g[1] ?? "") {
            var comps = calendar.dateComponents([.year, .month], from: today)
            comps.day = d
            if var candidate = calendar.date(from: comps) {
                if candidate < today { candidate = calendar.date(byAdding: .month, value: 1, to: candidate)! }
                day = candidate
            }
        }

        // Time ranges: "3-5pm", "from 9:30 to 11", "noon-1"
        let rangePattern = #"(?<![\d/:])(from\s+)?"# + Self.timePattern + #"\s*(?:-|–|—|to|until|till)\s*"# + Self.timePattern + #"(?![\d/:])\b"#
        if let g = take(rangePattern, from: &text, validate: { g in
            let hasMeridiem = g[4] != nil || g[8] != nil
            let hasColon = g[3] != nil || g[7] != nil
            let hasWord = g[5] != nil || g[9] != nil
            return hasMeridiem || hasColon || hasWord || g[1] != nil
        }) {
            let s = parseTime(hour: g[2], minute: g[3], meridiem: g[4], word: g[5])
            let e = parseTime(hour: g[6], minute: g[7], meridiem: g[8], word: g[9])
            if var s, var e {
                startHadMeridiem = g[4] != nil || g[5] != nil
                endHadMeridiem = g[8] != nil || g[9] != nil
                if !startHadMeridiem, endHadMeridiem, let em = g[8] {
                    // "3-5pm" → 3pm, but "11-1pm" → 11am
                    let inherited = resolveHour(s.hour, meridiem: em, eveningContext: eveningContext)
                    let endHour = resolveHour(e.hour, meridiem: em, eveningContext: eveningContext)
                    s.hour = inherited <= endHour ? inherited : resolveHour(s.hour, meridiem: "am", eveningContext: false)
                    startHadMeridiem = true
                } else if !startHadMeridiem {
                    s.hour = resolveHour(s.hour, meridiem: nil, eveningContext: eveningContext)
                }
                if g[8] != nil { e.hour = resolveHour(e.hour, meridiem: g[8], eveningContext: eveningContext) }
                else if g[9] == nil {
                    // "9-10:30", "1-3": end follows start's half of the day
                    e.hour = e.hour < 12 && s.hour >= 12 && e.hour + 12 > s.hour ? e.hour + 12 : resolveHour(e.hour, meridiem: nil, eveningContext: eveningContext)
                }
                startTime = s
                endTime = e
            }
        } else if let g = take(#"(?:\b(at|@)\s*)?(?<![\d/:])"# + Self.timePattern + #"(?![\d/:])\b"#, from: &text, validate: { g in
            g[4] != nil || g[3] != nil || g[5] != nil || (g[1] != nil && g[2] != nil)
        }) {
            if var t = parseTime(hour: g[2], minute: g[3], meridiem: g[4], word: g[5]) {
                startHadMeridiem = g[4] != nil || g[5] != nil
                if g[5] == nil { t.hour = resolveHour(t.hour, meridiem: g[4], eveningContext: eveningContext) }
                startTime = t
            }
        }

        // Fuzzy times of day
        if let g = take(#"\b(?:this\s+|in\s+the\s+)?(morning|afternoon|evening|tonight|night)\b"#, from: &text) {
            switch g[1] {
            case "morning": timeHint = (9, 0)
            case "afternoon": timeHint = (14, 0)
            case "evening": timeHint = (18, 0)
            default:
                timeHint = (20, 0)
                if day == nil { day = today }
            }
        }

        // Location: "@ Starbucks" or "at The Library" (whatever trails)
        var location: String?
        if let g = take(#"\s@\s*([^@]+?)\s*$"#, from: &text, caseSensitive: true) {
            location = g[1]
        } else if let g = take(#"\s(?:at|in)\s+((?:the\s+)?[A-Z0-9][^@]*?)\s*$"#, from: &text, caseSensitive: true) {
            location = g[1]
        } else if let g = take(#"\sat\s+(the\s+[^@]+?)\s*$"#, from: &text, caseSensitive: true) {
            location = g[1]
        }
        location = location.map(cleanTitle).flatMap { $0.isEmpty ? nil : $0 }

        // MARK: Assemble
        var result = ParsedEntry(kind: .event, title: cleanTitle(text), start: nil, end: nil, isAllDay: false,
                                 hasExplicitTime: false, location: location, tag: tag, recurrence: recurrence,
                                 durationMinutes: duration, priority: priority)

        if let rel = relativeStart {
            if relativeHasTime && startTime == nil {
                let rounded = roundToFiveMinutes(rel)
                day = calendar.startOfDay(for: rounded)
                let c = calendar.dateComponents([.hour, .minute], from: rounded)
                startTime = (c.hour ?? 0, c.minute ?? 0)
            } else if day == nil {
                day = calendar.startOfDay(for: rel)
            }
        }

        if day == nil, recurrence.isRepeating {
            switch recurrence.frequency {
            case .weekly where !recurrence.weekdays.isEmpty:
                day = recurrence.weekdays.compactMap { nextWeekday($0, includeToday: true) }.min()
            case .weekdays:
                day = (0..<7).lazy.compactMap { self.calendar.date(byAdding: .day, value: $0, to: today) }
                    .first { (2...6).contains(self.calendar.component(.weekday, from: $0)) }
            default:
                day = today
            }
        }

        let time = startTime ?? timeHint
        // "monday 8am" said on Monday afternoon means next Monday.
        if dayIsBareWeekday, let d = day, calendar.isDate(d, inSameDayAs: now), let t = startTime, at(d, t) <= now {
            day = calendar.date(byAdding: .day, value: 7, to: d)
        }
        if recurrence.isRepeating, startTime != nil, let d0 = day, let t = time, at(d0, t) <= now {
            day = (1...31).lazy.compactMap { self.calendar.date(byAdding: .day, value: $0, to: d0) }.first { candidate in
                let wd = self.calendar.component(.weekday, from: candidate)
                switch recurrence.frequency {
                case .daily: return true
                case .weekdays: return (2...6).contains(wd)
                case .weekly: return recurrence.weekdays.isEmpty ? wd == self.calendar.component(.weekday, from: d0) : recurrence.weekdays.contains(wd)
                default: return self.calendar.component(.day, from: candidate) == self.calendar.component(.day, from: d0)
                }
            }
        }
        if day == nil, let t = time {
            let candidate = at(today, t)
            day = candidate > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }

        // School work is an assignment (to-do with a due date) unless it clearly describes an event:
        // a time range, a repeating schedule, or event words like "practice", "meeting", "test".
        let assignmentByContext = looksLikeAssignment && !looksLikeEvent && endTime == nil && !recurrence.isRepeating
        let isTask = forcedTask || assignmentByContext || (day == nil && time == nil && !recurrence.isRepeating)
        result.course = detectCourse(input)
        result.kind = isTask ? .task : .event
        result.hasExplicitTime = startTime != nil

        guard let d = day else { return result }

        if isTask {
            result.start = time.map { at(d, $0) } ?? at(d, (23, 59))
            return result
        }

        if let t = time {
            let s = at(d, t)
            result.start = s
            if let e = endTime {
                var end = at(d, e)
                if end <= s { end = !endHadMeridiem && end.addingTimeInterval(12 * 3600) > s ? end.addingTimeInterval(12 * 3600) : calendar.date(byAdding: .day, value: 1, to: end)! }
                result.end = end
                result.durationMinutes = Int(end.timeIntervalSince(s) / 60)
            } else {
                result.end = s.addingTimeInterval(Double(duration ?? 60) * 60)
            }
        } else {
            result.isAllDay = true
            result.start = d
            result.end = calendar.date(byAdding: .day, value: 1, to: d)
        }
        return result
    }

    // MARK: Helpers

    private func parseTime(hour: String?, minute: String?, meridiem: String?, word: String?) -> HM? {
        if let word {
            return word == "noon" ? (12, 0) : (0, 0)
        }
        guard let h = hour.flatMap({ Int($0) }), h <= 23 else { return nil }
        let m = minute.flatMap { Int($0) } ?? 0
        guard m < 60 else { return nil }
        if meridiem != nil && (h == 0 || h > 12) { return nil }
        return (h, m)
    }

    private func resolveHour(_ h: Int, meridiem: String?, eveningContext: Bool) -> Int {
        if let m = meridiem {
            let pm = m.hasPrefix("p")
            if h == 12 { return pm ? 12 : 0 }
            return pm ? h + 12 : h
        }
        if h >= 13 || h == 0 { return h }
        if h == 12 { return 12 }
        if eveningContext { return h + 12 }
        // A bare "at 3" almost always means the afternoon; "at 9" usually the morning.
        return (1...6).contains(h) ? h + 12 : h
    }

    private func at(_ day: Date, _ t: HM) -> Date {
        calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day) ?? day
    }

    private func roundToFiveMinutes(_ date: Date) -> Date {
        let c = calendar.dateComponents([.minute], from: date)
        let extra = (5 - (c.minute ?? 0) % 5) % 5
        let rounded = calendar.date(byAdding: .minute, value: extra, to: date) ?? date
        return calendar.date(bySetting: .second, value: 0, of: rounded) ?? rounded
    }

    private func nextWeekday(_ weekday: Int, includeToday: Bool) -> Date? {
        let today = calendar.startOfDay(for: now)
        let current = calendar.component(.weekday, from: today)
        var diff = (weekday - current + 7) % 7
        if diff == 0 && !includeToday { diff = 7 }
        return calendar.date(byAdding: .day, value: diff, to: today)
    }

    /// Weeks run Monday–Sunday for "next friday" style phrases.
    private func isInCurrentWeek(_ date: Date) -> Bool {
        let today = calendar.startOfDay(for: now)
        let iso = (calendar.component(.weekday, from: today) + 5) % 7 + 1 // Mon=1 … Sun=7
        let nextMonday = calendar.date(byAdding: .day, value: 8 - iso, to: today)!
        return date < nextMonday
    }

    private func makeDate(month: Int?, day: Int?, year: Int?) -> Date? {
        guard let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let today = calendar.startOfDay(for: now)
        var comps = DateComponents(year: year ?? calendar.component(.year, from: today), month: month, day: day)
        guard var date = calendar.date(from: comps) else { return nil }
        if year == nil, date < calendar.date(byAdding: .day, value: -1, to: today)! {
            comps.year = (comps.year ?? 0) + 1
            date = calendar.date(from: comps) ?? date
        }
        return date
    }

    private func cleanTitle(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dangling = #"^(on|at|from|for|in|by|due|to|-|–|,|\.)\s+|\s+(on|at|from|for|in|by|due|to|starting|-|–|,|\.)$"#
        var previous = ""
        while previous != s {
            previous = s
            s = s.replacingOccurrences(of: dangling, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.-–")))
        }
        if let first = s.first, first.isLowercase { s = first.uppercased() + s.dropFirst() }
        return s
    }
}
