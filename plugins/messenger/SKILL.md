---
name: messenger
description: Read before reading, searching or sending the user's Facebook Messenger messages, or signing Messenger in.
---

Messenger is the user's Facebook Messenger, read through messenger.com in a browser on one of their devices. Each
account is a sign-in there, named by the user (Personal, Work), as `accounts` lists them; the other tools take
`account`, the first by default. Each takes some seconds: a browser does the reading.

- `chats` lists recent chats, `read` reads one, `search` finds messages. Opening a chat marks it read, so `read`
  marks an unread one unread again, though the sender may see it as seen.
- `send` sends a real message to a real person, and can't be taken back: only when the user asked, with the exact
  text they approved.
- If Messenger signed an account out, the tools say so. `sign_in` opens a browser window at messenger.com on one
  of their devices (`device`, from `devices`), where they sign in themselves, at that device's screen; never sign
  in for them. It's kept once their chats show.
- `sign_out` stops reading an account and deletes its session here, only when the user asks.

A device runs Messenger's browser once its service is installed there: `install_service --plugin messenger
--service Messenger.Browser --server <key>`. It needs Bun and a Chromium (`bunx playwright install chromium`) or
Chrome. A session is kept encrypted under a key in the user's Vault, so a server must be chosen to open their
Vault (`vault_grant`) before an account is signed in.
