import AppKit
import Contacts
import EventKit

/// The permissions macOS gives the helper, each asked for at most once a run: macOS shows its question on the Mac's
/// screen, and the call that asked says so rather than waiting for an answer that may come hours later.
enum Permissions {
    nonisolated(unsafe) static var asked = Set<String>()

    static func run(_ function: String, _ input: Input) throws -> Any {
        guard function == "permissions" else { throw Refusal("mac has no function \(function)") }
        return [
            "helper": Bundle.main.bundlePath,
            "calendars": said(events(.event)), "reminders": said(events(.reminder)), "contacts": said(contacts()),
            "messages": MessagesPart.readable() ? "allowed" : "needs Full Disk Access",
            "sending": automation(),
        ]
    }

    enum Access { case granted, denied, unasked }

    static func said(_ access: Access) -> String {
        switch access {
        case .granted: "allowed"
        case .denied: "not allowed"
        case .unasked: "not asked yet"
        }
    }

    static func events(_ type: EKEntityType) -> Access {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: .granted
        case .notDetermined: .unasked
        default: .denied
        }
    }

    static func contacts() -> Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: .granted
        case .notDetermined: .unasked
        default: .denied
        }
    }

    /// Goes on only with `access` granted. Unasked, it asks macOS, once a run, and says where to answer; denied, it
    /// says where to allow it. `what` finishes "may …", and `allow` says what to do in the Settings pane `pane`.
    static func need(_ access: Access, _ what: String, pane: String, allow: String, ask: () -> Void) throws {
        switch access {
        case .granted:
            return
        case .unasked:
            if asked.insert(pane).inserted { ask() }
            throw Refusal("macOS is asking on the Mac's screen whether \(thisApp) may \(what). Click Allow there, then ask again.")
        case .denied:
            throw Refusal("macOS doesn't let \(thisApp) \(what). Allow it on the Mac in System Settings → Privacy & Security → \(pane): \(allow).")
        }
    }

    static func calendars() throws {
        try need(events(.event), "have full access to your calendars", pane: "Calendars",
                 allow: "set \(thisApp) to Full Access") { EKEventStore().requestFullAccessToEvents { _, _ in } }
    }

    static func reminders() throws {
        try need(events(.reminder), "use your reminders", pane: "Reminders",
                 allow: "turn on \(thisApp)") { EKEventStore().requestFullAccessToReminders { _, _ in } }
    }

    static func people() throws {
        try need(contacts(), "use your contacts", pane: "Contacts",
                 allow: "turn on \(thisApp)") { CNContactStore().requestAccess(for: .contacts) { _, _ in } }
    }

    /// Whether macOS lets the helper control Messages, to send: it can tell only while Messages is open.
    static func automation() -> String {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) {
        case noErr: return "allowed"
        case OSStatus(errAEEventNotPermitted): return "not allowed"
        case OSStatus(errAEEventWouldRequireUserConsent): return "not asked yet"
        default: return "not known while Messages is closed"
        }
    }
}
