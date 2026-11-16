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
struct Refusal: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// This helper's name, as macOS shows it where it asks and in Privacy & Security.
let thisApp = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "The One App Helper"

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
