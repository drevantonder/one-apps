---
name: apple-reminders
description: Read when the user asks about their Apple Reminders, or to add, change, tick off or delete one, through their Mac.
metadata:
  title: "Apple Reminders"
  subtitle: "Your Mac's reminders"
  about: "Your AI adds, changes and ticks off your Apple Reminders, through your Mac, so they're on your iPhone too."
  category: Connectors
---

Reminders are the user's Apple Reminders, through their Mac, and sync to their other Apple devices. `lists` lists
the lists; `list` lists reminders, soonest due first, leaving out completed ones unless asked. `update` also
completes one, with `completed`. `delete` can't be undone: to tick one off instead, use `update`.

It reaches the Mac through its service `AppleReminders.Helper`, which runs a small app there, Apple
Reminders for the One App: `install_service --app apple-reminders --service AppleReminders.Helper --server <key>`
(`services` gives the key). The first time a tool runs, macOS asks on the Mac's screen whether that app may use the
reminders, and the tool waits up to 30 seconds for their answer. If no one answers by then, it says macOS is still asking there:
only the Mac's person can answer, so tell them to click Allow, then ask again. If it's turned off, the tool says
so, with the link that opens System Settings where they turn it on.
