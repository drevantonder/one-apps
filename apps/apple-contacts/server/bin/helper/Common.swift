import Foundation

/// Starts this program again, macOS holding it responsible for itself, with the same input and output, and gives its
/// exit status once it ends. `responsibility_spawnattrs_setdisclaim` is how Terminal and Xcode do this; it isn't in
/// macOS's headers, so it's looked up, and a macOS without it is said to be one.
func startedAsItself() -> Int32 {
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    guard let found = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
        FileHandle.standardError.write(Data("This macOS has no responsibility_spawnattrs_setdisclaim, so the helper can't ask for permissions under its own name\n".utf8))
        return 1
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    _ = unsafeBitCast(found, to: Disclaim.self)(&attributes, 1)
    setenv("ONE_HELPER_OWN", "1", 1)
    let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
    var pid = pid_t()
    let started = posix_spawn(&pid, path, nil, &attributes, argv, environ)
    guard started == 0 else {
        FileHandle.standardError.write(Data("The helper couldn't start itself: \(String(cString: strerror(started)))\n".utf8))
        return 1
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 1
}

/// What's the caller's to change, or what went wrong, in words for whoever asked.
/// What's the caller's to change, or what went wrong, in words for whoever asked.
struct Refusal: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// This helper's name, as macOS shows it where it asks and in Privacy & Security.
let thisApp = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "this helper"

/// A call's inputs, read leniently: the CLI sends a flag that looks like a number as one.
struct Input {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func has(_ key: String) -> Bool { raw[key] != nil && !(raw[key] is NSNull) }

    func string(_ key: String) -> String? {
        switch raw[key] {
        case let s as String: s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    func text(_ key: String) throws -> String {
        guard let s = string(key) else { throw Refusal("give \(key)") }
        return s
    }

    func int(_ key: String, or fallback: Int) -> Int {
        (raw[key] as? NSNumber)?.intValue ?? string(key).flatMap { Int($0) } ?? fallback
    }

    func bool(_ key: String) -> Bool? { raw[key] as? Bool ?? string(key).map { $0 == "true" } }

    func date(_ key: String) throws -> When? {
        guard let s = string(key) else { return nil }
        guard let when = When(s) else {
            throw Refusal("\(key) must be an ISO 8601 date (2026-11-01) or date-time (2026-11-01T09:00 or 2026-11-01T09:00:00+10:00)")
        }
        return when
    }
}

/// A time a caller gave: a moment, or a whole day.
struct When {
    var date: Date
    var day: Bool

    /// ISO 8601: a date, or a date-time with or without its offset (then it's this Mac's time zone).
    init?(_ s: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        let s = s.replacingOccurrences(of: " ", with: "T")
        for (format, day) in [("yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", false), ("yyyy-MM-dd'T'HH:mm:ssXXXXX", false),
                              ("yyyy-MM-dd'T'HH:mmXXXXX", false), ("yyyy-MM-dd'T'HH:mm:ss", false),
                              ("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd", true)] {
            f.dateFormat = format
            if let date = f.date(from: s) {
                (self.date, self.day) = (date, day)
                return
            }
        }
        return nil
    }
}

/// A moment in this Mac's time zone, as 2026-11-01T09:00:00+10:00.
func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f.string(from: date)
}

/// A day, as 2026-11-01.
func isoDay(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
}

/// A JSON object without the fields that have nothing.
func object(_ fields: [String: Any?]) -> [String: Any] { fields.compactMapValues { $0 } }

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Where a permission of macOS's stands for this helper. macOS keeps the person's answer under the helper's
/// signature, so it's allowed or denied from then on, and unknown until they answer.
enum Access { case allowed, denied, unknown }

/// A permission a call needs, which macOS asks the Mac's person for in this helper's name:
///
///     unknown ── a call needs it ──▶ asking: macOS's question is on the Mac's screen ──▶ allowed | denied
///                                └─▶ not asked: macOS said no without asking, and it's still unknown
///
/// A call waits up to `patience` for the answer while macOS asks, so a person at the Mac who clicks Allow gets what
/// they asked for, and one that waits longer is told macOS is still asking. Denied, it says how to allow it, with the
/// link that opens System Settings at its pane. `what` finishes "may …", and `allow` says what to do in the pane.
final class Permission: @unchecked Sendable {
    let what: String, pane: String, anchor: String, allow: String
    let access: () -> Access
    let request: (@escaping @Sendable () -> Void) -> Void
    /// Signalled once macOS answers the request it's asking, while there's one.
    private var answer: DispatchSemaphore?

    init(_ what: String, pane: String, anchor: String, allow: String, access: @escaping () -> Access,
         request: @escaping (@escaping @Sendable () -> Void) -> Void) {
        (self.what, self.pane, self.anchor, self.allow, self.access, self.request) = (what, pane, anchor, allow, access, request)
    }

    func need() throws {
        switch access() {
        case .allowed: answer = nil; return
        case .denied: answer = nil; throw denied
        case .unknown: break
        }
        if answer == nil {
            let answered = DispatchSemaphore(value: 0)
            answer = answered
            request { answered.signal() }
        }
        guard answer!.wait(timeout: .now() + patience) == .success else {
            throw Refusal("macOS is asking on the Mac's screen whether \(thisApp) may \(what). Click Allow there, then ask again.")
        }
        answer = nil
        switch access() {
        case .allowed: return
        case .denied: throw denied
        case .unknown:
            throw Refusal("macOS said no without asking whether \(thisApp) may \(what), so there's nothing to allow on the Mac: " +
                          "this build of \(thisApp) can't be given it. The Mac's log says why: " +
                          "log show --last 5m --predicate 'subsystem == \"com.apple.TCC\"'")
        }
    }

    var denied: Refusal {
        Refusal("macOS doesn't let \(thisApp) \(what): it's turned off on the Mac. To allow it, open System Settings → " +
                "Privacy & Security → \(pane) on the Mac (\(settings(anchor))) and \(allow).")
    }
}

/// How long a call waits for the Mac's person to answer macOS's question.
let patience: TimeInterval = 30

/// The link that opens System Settings at the pane of Privacy & Security that `anchor` names.
func settings(_ anchor: String) -> String { "x-apple.systempreferences:com.apple.preference.security?\(anchor)" }
