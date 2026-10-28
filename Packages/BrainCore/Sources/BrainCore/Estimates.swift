import Foundation

/// How long things take when you didn't say: a to-do by what you're actually doing
/// ("sign up for the tournament" is a 10-minute form, not the tournament), an event by what it is.
public enum Estimates {
    /// Leading filler that doesn't change the job: "need to", "remember to", "pls".
    static let filler = #"^\s*(?:(?:i\s+)?(?:need to|have to|gotta|got to|should|must|remember to|don'?t forget to|pls|please|todo:?|to-do:?)\s+)+"#

    /// Errands, chores and quick admin, first match wins. Checked before anything else,
    /// so the verb decides: "sign up for X" is quick whatever X is.
    static let errandTable: [(pattern: String, minutes: Int)] = [
        // Quick admin
        (#"^(sign ?up|register|enroll|rsvp)\b"#, 10),
        (#"^(fill out|complete the form|submit the form)\b|\bpermission slip\b|\bform\b"#, 10),
        (#"^(text|message|dm|reply|respond|venmo|ask|tell|remind|thank)\b"#, 5),
        (#"^(e-?mail|follow up)\b"#, 10),
        (#"^(call|phone|facetime)\b"#, 15),
        (#"^(pay|renew|book|reserve|schedule|reschedule|cancel|confirm|order|unsubscribe|deposit)\b"#, 10),
        (#"^(print|scan|charge|sign)\b"#, 5),
        (#"^(turn in|hand in|submit|upload)\b"#, 5),
        (#"^(look up|google|check|find)\b"#, 10),
        (#"^(download|install|update|back ?up|set ?up)\b"#, 15),
        // Chores and errands
        (#"\b(take out|empty) (the )?(trash|garbage|recycling)\b|\btrash\b"#, 5),
        (#"\bmake (my |the )?bed\b"#, 3),
        (#"^(water|feed)\b"#, 5),
        (#"\bwalk (the )?dog\b"#, 30),
        (#"\b(laundry|fold|iron)\b"#, 20),
        (#"\bdishes\b"#, 20),
        (#"\b(vacuum|sweep|mop|dust)\b"#, 20),
        (#"^(clean|tidy|organi[sz]e|declutter)\b"#, 45),
        (#"\b(groceries|grocery|costco|target|mall)\b|^shop\b"#, 60),
        (#"^(pick up|drop off|return|exchange|bring|grab|get|buy)\b"#, 20),
        (#"^(pack|unpack)\b"#, 20),
        (#"\bhaircut\b"#, 45),
        (#"^(cook|bake)\b"#, 45),
    ]

    /// School work, first match wins.
    static let schoolTable: [(pattern: String, minutes: Int)] = [
        (#"\b(research paper|final project|science fair)\b"#, 180),
        (#"\b(essay|paper|lab report)\b"#, 120),
        (#"\b(project|presentation|slides)\b"#, 120),
        (#"\b(practice test|practice exam|mock exam)\b"#, 90),
        (#"\b(rough draft|final draft|draft)\b"#, 90),
        (#"\bstud(y|ying)\b|\breview for\b"#, 60),
        (#"\b(problem ?set|pset)\b"#, 60),
        (#"\b(frq|dbq|leq|saq)\b"#, 45),
        (#"\b(read|reading|chapter|ch\.?\s*\d)\b"#, 40),
        (#"\b(home ?work|hw)\b"#, 40),
        (#"\bworksheet\b"#, 35),
        (#"\b(notes|outline|annotat\w*)\b"#, 30),
        (#"\b(flashcards|vocab)\b"#, 20),
        (#"\b(discussion post|journal|reflection)\b"#, 20),
        (#"\b(practice|memorize)\b"#, 30),
    ]

    /// Events, first match wins. All-day things (a tournament with no time) are handled by the caller.
    static let eventTable: [(pattern: String, minutes: Int)] = [
        (#"\b(sign ?up|registration) (deadline|due)\b"#, 15),
        (#"\b(tournament|competition|meet|regionals|nationals|states|convention|hackathon|fair|festival|camp)\b"#, 480),
        (#"\b(sat|act|psat)\b"#, 240),
        (#"\bap (exam|test)\b"#, 195),
        (#"\b(final|midterm)s?\b"#, 120),
        (#"\bstudy (group|session)\b"#, 90),
        (#"\b(exam)\b"#, 120),
        (#"\b(quiz)\b"#, 30),
        (#"\b(test)\b"#, 60),
        (#"\b(practice|rehearsal|tryouts?|scrimmage)\b"#, 120),
        (#"\b(game|match|bout)\b"#, 120),
        (#"\b(call|zoom|facetime|phone)\b"#, 30),
        (#"\binterview\b"#, 45),
        (#"\b(dentist|orthodontist|doctor|physical|checkup|check-up|therapy|appointment|appt)\b"#, 60),
        (#"\bhaircut\b"#, 45),
        (#"\bcoffee\b"#, 45),
        (#"\b(dinner|brunch)\b"#, 90),
        (#"\b(lunch|breakfast)\b"#, 60),
        (#"\bmovie\b"#, 150),
        (#"\b(party|concert|show|play|musical|hangout|sleepover)\b"#, 180),
        (#"\b(recital|ceremony|graduation|banquet)\b"#, 120),
        (#"\b(church|service|mass|temple|mosque)\b"#, 75),
        (#"\bflight\b"#, 180),
        (#"\b(gym|workout|lift|swim|yoga)\b"#, 60),
        (#"\b(run|jog)\b"#, 45),
        (#"\b(class|lesson|lecture|tutor\w*|club|meeting|office hours)\b"#, 60),
        (#"\bshift\b"#, 240),
    ]

    private static func first(_ table: [(pattern: String, minutes: Int)], in title: String) -> Int? {
        let t = title.lowercased().replacingOccurrences(of: filler, with: "", options: .regularExpression)
        return table.first { t.range(of: $0.pattern, options: .regularExpression) != nil }?.minutes
    }

    /// Minutes for a to-do you didn't put a time on. `learned`: your average for that class, used for school work.
    public static func taskMinutes(for title: String, learned: Int? = nil) -> Int {
        if let m = first(errandTable, in: title) { return m }
        if let learned { return learned }
        return first(schoolTable, in: title) ?? 30
    }

    /// Minutes for an event with a start time but no end.
    public static func eventMinutes(for title: String) -> Int { first(eventTable, in: title) ?? 60 }

    /// Errands and admin (forms, messages, chores) are never "big projects", whatever they mention.
    public static func isErrand(_ title: String) -> Bool { first(errandTable, in: title) != nil }
}
