---
name: apple-reminders
description: Read when the user asks about their Apple Reminders, or to add, change, tick off or delete one, through their Mac.
metadata:
  subtitle: "Your Mac's reminders"
  about: "Your AI adds, changes and ticks off your Apple Reminders, through your Mac, so they're on your iPhone too."
  category: Productivity
---

Reminders are the user's Apple Reminders, through their Mac, and sync to their other Apple devices. `lists` lists
the lists; `list` lists reminders, soonest due first, leaving out completed ones unless asked. `update` also
completes one, with `completed`. `delete` can't be undone: to tick one off instead, use `update`.

It reaches the Mac through its service `AppleReminders.Helper`, which builds and runs a small app there, Apple
Reminders for The One App: `install_service --app apple-reminders --service AppleReminders.Helper --server <key>`
(`services` gives the key); the Mac needs Xcode or its Command Line Tools. The first time a tool runs, macOS asks on
the Mac's screen whether that app may use the reminders, and the tool says it's waiting for permission on the Mac.
Only the Mac's person can answer it: tell them to click Allow, then ask again.
