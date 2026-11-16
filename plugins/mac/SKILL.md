---
name: mac
description: Read when Calendar, Reminders, Contacts or iMessage says macOS hasn't allowed something, or to set them up on a Mac.
---

Calendar, Reminders, Contacts and iMessage reach the user's Mac through this plugin's service, `Mac.Helper`, which
builds and runs a small app there, The One App Helper. Install it on the Mac with `install_service --plugin mac
--service Mac.Helper --server <key>` (`services` gives the key); the Mac needs Xcode or its Command Line Tools.

macOS asks the Mac's person for each permission under The One App Helper's name: Calendars, Reminders and Contacts
on the Mac's screen the first time a tool needs them, and Automation of Messages the first time a message is sent.
Reading messages needs Full Disk Access, which macOS never asks for: the person turns it on in System Settings →
Privacy & Security → Full Disk Access. `permissions` says which are given, and where the app is to add it there.
When a tool says macOS is asking, the person answers on the Mac; nothing an agent does can answer for them.
