---
name: apple-calendar
description: Read when the user asks about their Apple Calendar or what's on, or to add, move or delete an event, through their Mac.
---

Calendar is the user's Apple Calendar through their Mac: every account it has, such as iCloud, Google or Exchange.
`events` lists events in a time range, by default the coming week; `calendars` lists the calendars, and only
writable ones take new events. Times are ISO 8601; without an offset they're in the Mac's time zone. A repeating
event's id names one occurrence: `update` and `delete` change just it, or with `future` it and every later one.
`delete` can't be undone: the calendar's account deletes it everywhere, so delete only what the user asked to.

It reaches the Mac through the plugin `mac`, whose skill says how it's set up and what macOS asks for.
