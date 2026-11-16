---
name: imessage
description: Read when the user asks about their iMessages or texts, or wants one sent, through their Mac.
---

iMessage is the user's Messages on their Mac, iMessage and SMS. `chats` lists recent chats; `read` reads one,
newest last; `search` finds messages. Each list pages back with `limit` and `skip`. Reading never marks a message
read. A message shows who it's from by their name in Contacts once Contacts is allowed, and by their number until
then.

`send` sends a real message to a real person, which can't be taken back: send only what the user asked to send, to
whom they asked, and show them the exact text first.

It reaches the Mac through the plugin `mac`, whose skill says how it's set up and what macOS asks for.
