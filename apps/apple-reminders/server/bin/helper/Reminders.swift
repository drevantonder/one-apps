import EventKit
import Foundation

/// Reminders, through EventKit, which needs full access to the Mac's reminders. Each call opens its own store and is
/// done with what it fetched before it answers.
func run(_ function: String, _ input: Input) throws -> Any {
    try reminders.need()
    return try RemindersPart.run(function, input)
}

let reminders = Permission(
    "use your reminders", pane: "Reminders", anchor: "Privacy_Reminders", allow: "turn on \(thisApp)",
    access: {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .allowed
        case .notDetermined: .unknown
        default: .denied
        }
    },
    request: { answered in
        let store = EKEventStore()
        store.requestFullAccessToReminders { _, _ in withExtendedLifetime(store) { answered() } }
    })

enum RemindersPart {
    static func run(_ function: String, _ input: Input) throws -> Any {
        let store = EKEventStore()
        switch function {
        case "lists":
            let preferred = store.defaultCalendarForNewReminders()?.calendarIdentifier
            return store.calendars(for: .reminder).map { c in
                object(["name": c.title, "id": c.calendarIdentifier, "account": c.source?.title,
                        "default": c.calendarIdentifier == preferred ? true : nil])
            }
        case "list":
            let lists = try calendar(store, .reminder, input.string("list")).map { [$0] }
            let until = try input.date("until").map { $0.day ? Calendar.current.date(byAdding: .day, value: 1, to: $0.date)! : $0.date }
            let completed = input.bool("completed") ?? false
            var found = fetch(store, completed ? store.predicateForReminders(in: lists)
                : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: until, calendars: lists))
            if completed, let until { found = found.filter { due($0).map { $0 < until } ?? false } }
            if let q = input.string("query") {
                found = found.filter { ($0.title ?? "").localizedCaseInsensitiveContains(q) || ($0.notes ?? "").localizedCaseInsensitiveContains(q) }
            }
            found.sort { (due($0) ?? .distantFuture, $0.title ?? "") < (due($1) ?? .distantFuture, $1.title ?? "") }
            return found.prefix(input.int("limit", or: 100)).map(json)
        case "create":
            let r = EKReminder(eventStore: store)
            r.title = try input.text("title")
            guard let list = try calendar(store, .reminder, input.string("list")) ?? store.defaultCalendarForNewReminders() else {
                throw Refusal("there's no default list; give one")
            }
            r.calendar = list
            r.notes = input.string("notes")
            try edit(r, input)
            try store.save(r, commit: true)
            return json(r)
        case "update":
            let r = try reminder(store, input)
            if let title = input.string("title") { r.title = title }
            if let list = try calendar(store, .reminder, input.string("list")) { r.calendar = list }
            if input.has("notes") { r.notes = input.string("notes") }
            if let completed = input.bool("completed") { r.isCompleted = completed }
            try edit(r, input)
            try store.save(r, commit: true)
            return json(r)
        case "delete":
            let r = try reminder(store, input)
            try store.remove(r, commit: true)
            return "Deleted \(r.title ?? "the reminder")."
        default:
            throw Refusal("reminders has no function \(function)")
        }
    }

    private static func fetch(_ store: EKEventStore, _ predicate: NSPredicate) -> [EKReminder] {
        nonisolated(unsafe) var found: [EKReminder] = []
        let done = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: predicate) { reminders in
            found = reminders ?? []
            done.signal()
        }
        done.wait()
        return found
    }

    private static func reminder(_ store: EKEventStore, _ input: Input) throws -> EKReminder {
        let id = try input.text("id")
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Refusal("no reminder with id \(id); apple-reminders_list lists them") }
        return r
    }

    /// Sets the due date and priority a call gives. A due time also alerts then, as it does when set in Reminders.
    private static func edit(_ r: EKReminder, _ input: Input) throws {
        if let p = input.string("priority") {
            guard let value = ["none": 0, "high": 1, "medium": 5, "low": 9][p.lowercased()] else { throw Refusal("priority is high, medium, low or none") }
            r.priority = value
        }
        guard input.has("due") else { return }
        r.alarms?.forEach(r.removeAlarm)
        if ["none", "null", ""].contains(input.string("due")?.lowercased() ?? "") {
            r.dueDateComponents = nil
            return
        }
        guard let when = try input.date("due") else { return }
        r.dueDateComponents = Calendar.current.dateComponents(when.day ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: when.date)
        if !when.day { r.addAlarm(EKAlarm(absoluteDate: when.date)) }
    }

    private static func due(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { Calendar.current.date(from: $0) } }

    private static func json(_ r: EKReminder) -> [String: Any] {
        let timed = r.dueDateComponents?.hour != nil
        let priority: String? = switch r.priority { case 1...4: "high"; case 5: "medium"; case 6...9: "low"; default: nil }
        return object([
            "id": r.calendarItemIdentifier, "title": r.title ?? "", "list": r.calendar?.title,
            "due": due(r).map { timed ? iso($0) : isoDay($0) }, "priority": priority, "notes": r.notes?.nonEmpty,
            "completed": r.isCompleted ? iso(r.completionDate ?? .now) : nil,
        ])
    }
}

/// A calendar or reminder list by its id or its name, any case; nil for none given.
func calendar(_ store: EKEventStore, _ type: EKEntityType, _ name: String?) throws -> EKCalendar? {
    guard let name else { return nil }
    let all = store.calendars(for: type)
    if let c = all.first(where: { $0.calendarIdentifier == name }) ?? all.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
        return c
    }
    throw Refusal("no \(type == .reminder ? "list" : "calendar") called \(name); there are \(all.map(\.title).joined(separator: ", "))")
}
