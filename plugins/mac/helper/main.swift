// The One App Helper: what of Calendar, Reminders, Contacts and Messages a Mac's apps and agents reach, through the
// frameworks macOS gives for each. Mac.Helper builds it as an app of its own and starts it; it reads one call a line,
// `{"part": "calendar", "function": "events", "inputs": {...}}`, and answers each with a line, `{"ok": ...}` or
// `{"error": "..."}`, in turn. It stops when its input closes, which is when the service that started it has gone.
//
// macOS asks for a permission, and keeps the answer, under the program it holds responsible for asking. A program
// a server starts would be the server's, `one`, which has no name or purpose of its own to ask with and is replaced
// by each update. So the helper first starts itself again as a process macOS holds responsible for itself, the way
// macOS's own Terminal starts a shell: then it asks as The One App Helper, and keeps what it's given.
import Foundation

if ProcessInfo.processInfo.environment["ONE_HELPER_OWN"] == nil {
    exit(startedAsItself())
}

let parts: [String: (String, Input) throws -> Any] = [
    "mac": Permissions.run, "calendar": CalendarPart.run, "reminders": RemindersPart.run,
    "contacts": ContactsPart.run, "imessage": MessagesPart.run,
]

Thread.detachNewThread {
    while let line = readLine() {
        let answer: [String: Any]
        do {
            guard let call = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let part = call["part"] as? String, let function = call["function"] as? String,
                  let run = parts[part] else { throw Refusal("the helper has no such call: \(line)") }
            answer = ["ok": try run(function, Input(call["inputs"] as? [String: Any] ?? [:]))]
        } catch {
            answer = ["error": "\(error)"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: answer, options: [.fragmentsAllowed]))
            ?? Data(#"{"error": "its answer isn't JSON"}"#.utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
    exit(0)
}
dispatchMain()

