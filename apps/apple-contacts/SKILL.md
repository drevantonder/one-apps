---
name: apple-contacts
description: Read when the user wants someone's number, email or address from their Apple Contacts, or their own, through their Mac.
metadata:
  title: "Apple Contacts"
  subtitle: "Your Mac's contacts"
  about: "Your AI finds anyone's number, email or address in Apple Contacts, through your Mac."
  category: Connectors
---

Contacts are the user's Apple Contacts, through their Mac. `search` finds people by name, email address or phone
number; `get` gives one card again by its id; `me` is the user's own card. Read-only.

It reaches the Mac through its service `AppleContacts.Helper`, which runs a small app there, Apple
Contacts for The One App: `install_service --app apple-contacts --service AppleContacts.Helper --server <key>`
(`services` gives the key). The first time a tool runs, macOS asks on the Mac's screen whether that app may use the
contacts, and the tool waits up to 30 seconds for their answer. If no one answers by then, it says macOS is still asking there:
only the Mac's person can answer, so tell them to click Allow, then ask again. If it's turned off, the tool says
so, with the link that opens System Settings where they turn it on.
