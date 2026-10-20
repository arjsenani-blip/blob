import Foundation

/// An assignment as it comes from Google Classroom.
struct ClassroomItem {
    var externalID: String
    var title: String
    var course: String
    var due: Date?
    var link: String?
    var isTurnedIn: Bool
    var workType: String?
    var maxPoints: Double?
    var description: String?
    /// NEW, CREATED, TURNED_IN, RETURNED, RECLAIMED_BY_STUDENT
    var state: String?
    var assignedGrade: Double?
    var isLate: Bool = false
    var assignedOn: Date?
}

/// Reads your courses, their published coursework, and your own submission state (turned in or not).
/// Read-only: it never changes anything in Classroom.
struct ClassroomService {
    let account: GoogleAccount

    private struct CoursesPage: Decodable { let courses: [Course]?; let nextPageToken: String? }
    private struct Course: Decodable { let id: String; let name: String; let section: String? }
    private struct WorkPage: Decodable { let courseWork: [Work]?; let nextPageToken: String? }
    private struct GDate: Decodable { let year: Int?; let month: Int?; let day: Int? }
    private struct GTime: Decodable { let hours: Int?; let minutes: Int? }
    private struct Work: Decodable {
        let id: String
        let title: String?
        let description: String?
        let alternateLink: String?
        let dueDate: GDate?
        let dueTime: GTime?
        let workType: String?
        let maxPoints: Double?
        let creationTime: String?
    }
    private struct SubmissionPage: Decodable { let studentSubmissions: [Submission]?; let nextPageToken: String? }
    private struct Submission: Decodable {
        let courseWorkId: String?
        let state: String?
        let assignedGrade: Double?
        let late: Bool?
    }

    func fetchAssignments(now: Date = Date()) async throws -> [ClassroomItem] {
        let courses = try await pages(CoursesPage.self, base: "https://classroom.googleapis.com/v1/courses?studentId=me&courseStates=ACTIVE&pageSize=100") {
            ($0.courses ?? [], $0.nextPageToken)
        }
        // Far enough back to cover the semester, so grades and finished work build up a history.
        let oldest = now.addingTimeInterval(-150 * 86_400)

        return try await withThrowingTaskGroup(of: [ClassroomItem].self) { group in
            for course in courses {
                group.addTask {
                    let base = "https://classroom.googleapis.com/v1/courses/\(course.id)"
                    async let works = pages(WorkPage.self, base: base + "/courseWork?courseWorkStates=PUBLISHED&orderBy=dueDate%20desc&pageSize=100") {
                        ($0.courseWork ?? [], $0.nextPageToken)
                    }
                    async let subs = pages(SubmissionPage.self, base: base + "/courseWork/-/studentSubmissions?userId=me&pageSize=100") {
                        ($0.studentSubmissions ?? [], $0.nextPageToken)
                    }
                    let (workList, subList) = try await (works, subs)
                    let subsByWork = Dictionary(subList.compactMap { s in s.courseWorkId.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
                    let created = ISO8601DateFormatter()
                    created.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let createdPlain = ISO8601DateFormatter()
                    return workList.compactMap { w -> ClassroomItem? in
                        let due = Self.dueDate(w.dueDate, w.dueTime)
                        if let due, due < oldest { return nil }
                        let assigned = w.creationTime.flatMap { created.date(from: $0) ?? createdPlain.date(from: $0) }
                        if due == nil, let c = assigned, c < oldest { return nil }
                        let sub = subsByWork[w.id]
                        return ClassroomItem(externalID: "\(course.id):\(w.id)", title: w.title ?? "Untitled",
                                             course: course.name, due: due, link: w.alternateLink,
                                             isTurnedIn: ["TURNED_IN", "RETURNED"].contains(sub?.state ?? ""), workType: w.workType,
                                             maxPoints: w.maxPoints, description: w.description,
                                             state: sub?.state, assignedGrade: sub?.assignedGrade, isLate: sub?.late ?? false,
                                             assignedOn: assigned)
                    }
                }
            }
            var all: [ClassroomItem] = []
            for try await chunk in group { all += chunk }
            return all
        }
    }

    /// Classroom stores due dates in UTC. No time means end of that day locally.
    private static func dueDate(_ d: GDate?, _ t: GTime?) -> Date? {
        guard let d, let y = d.year, let m = d.month, let day = d.day else { return nil }
        if let t {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            return utc.date(from: DateComponents(year: y, month: m, day: day, hour: t.hours ?? 0, minute: t.minutes ?? 0))
        }
        return Calendar.current.date(from: DateComponents(year: y, month: m, day: day, hour: 23, minute: 59))
    }

    private func pages<Page: Decodable, Item>(_ type: Page.Type, base: String,
                                              extract: (Page) -> ([Item], String?)) async throws -> [Item] {
        var items: [Item] = []
        var token: String?
        repeat {
            var url = base
            if let token { url += "&pageToken=\(token)" }
            let data = try await account.send(URLRequest(url: URL(string: url)!))
            let (chunk, next) = extract(try JSONDecoder().decode(Page.self, from: data))
            items += chunk
            token = next
        } while token != nil && items.count < 800
        return items
    }

    // MARK: Estimates

    /// First guess at how long an assignment takes. The app refines this per course from your actual times.
    static func estimate(for item: ClassroomItem) -> (minutes: Int, difficulty: Int) {
        let t = item.title.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if item.workType == "MULTIPLE_CHOICE_QUESTION" || item.workType == "SHORT_ANSWER_QUESTION" { return (15, 1) }
        if has("essay", "research", "project", "lab report", "presentation", "paper") { return (90, 3) }
        if has("test", "exam", "study guide", "review") { return (60, 3) }
        if has("quiz", "exit ticket", "warm up", "warm-up", "bell ringer") { return (20, 1) }
        if has("reading", "read ", "chapter", "notes") { return (30, 2) }
        if has("worksheet", "practice", "problem", "hw", "homework") { return (35, 2) }
        if let p = item.maxPoints, p >= 100 { return (60, 3) }
        return (40, 2)
    }
}
