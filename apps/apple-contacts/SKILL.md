---
name: apple-contacts
description: Read when the user wants someone's number, email or address from their Apple Contacts, or their own, through their Mac.
metadata:
  subtitle: "Your Mac's contacts"
  about: "Your AI finds anyone's number, email or address in Apple Contacts, through your Mac."
  category: Productivity
---

Contacts are the user's Apple Contacts, through their Mac. `search` finds people by name, email address or phone
number; `get` gives one card again by its id; `me` is the user's own card. Read-only.

It reaches the Mac through its service `AppleContacts.Helper`, which builds and runs a small app there, Apple
Contacts for The One App: `install_service --app apple-contacts --service AppleContacts.Helper --server <key>`
(`services` gives the key); the Mac needs Xcode or its Command Line Tools. The first time a tool runs, macOS asks on
the Mac's screen whether that app may use the contacts, and the tool says it's waiting for permission on the Mac.
Only the Mac's person can answer it: tell them to click Allow, then ask again.
