---
name: imessage
description: Read when the user asks about their iMessages or texts, or wants one sent, through their Mac.
metadata:
  subtitle: "Your Mac's texts"
  about: "Your AI reads and searches your iMessages and texts, and sends one when you ask, through your Mac."
  category: Connectors
---

iMessage is the user's Messages on their Mac, iMessage and SMS. `chats` lists recent chats; `read` reads one,
newest last; `search` finds messages. Each list pages back with `limit` and `skip`. Reading never marks a message
read. A message shows who it's from by their name in Contacts once Contacts is allowed, and by their number until
then.

`send` sends a real message to a real person, which can't be taken back: send only what the user asked to send, to
whom they asked, and show them the exact text first.

It reaches the Mac through its service `IMessage.Helper`, which builds and runs a small app there, iMessage for
The One App: `install_service --app imessage --service IMessage.Helper --server <key>` (`services` gives the key);
the Mac needs Xcode or its Command Line Tools. Reading needs Full Disk Access, which macOS never asks for: until the
Mac's person turns it on for iMessage for The One App in System Settings → Privacy & Security → Full Disk Access, a
tool says it's waiting for permission and where the app is. macOS asks on the Mac's screen to let it use Contacts the
first time it reads, and to let it control Messages the first time it sends. Only the Mac's person can answer these.
