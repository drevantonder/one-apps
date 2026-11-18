---
name: apple-calendar
description: Read when the user asks about their Apple Calendar or what's on, or to add, move or delete an event, through their Mac.
metadata:
  title: "Apple Calendar"
  subtitle: "Your Mac's calendar"
  about: "Your AI sees what's on in Apple Calendar, and adds, moves or deletes events, through your Mac."
  category: Connectors
---

Calendar is the user's Apple Calendar through their Mac: every account it has, such as iCloud, Google or Exchange.
`events` lists events in a time range, by default the coming week; `calendars` lists the calendars, and only
writable ones take new events. Times are ISO 8601; without an offset they're in the Mac's time zone. A repeating
event's id names one occurrence: `update` and `delete` change just it, or with `future` it and every later one.
`delete` can't be undone: the calendar's account deletes it everywhere, so delete only what the user asked to.

It reaches the Mac through its service `AppleCalendar.Helper`, which runs a small app there, Apple
Calendar for The One App: `install_service --app apple-calendar --service AppleCalendar.Helper --server <key>`
(`services` gives the key). The first time a tool runs, macOS asks on the Mac's screen whether that app may have
full access to the calendars, and the tool waits up to 30 seconds for their answer. If no one answers by then, it says macOS is still asking there:
only the Mac's person can answer, so tell them to click Allow, then ask again. If it's turned off, the tool says
so, with the link that opens System Settings where they turn it on.
