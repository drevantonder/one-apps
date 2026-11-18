---
name: whatsapp
description: Read before reading, searching or sending the user's WhatsApp messages, or linking a WhatsApp account.
metadata:
  title: "WhatsApp"
  subtitle: "Your WhatsApp chats"
  about: "Your AI reads and searches your WhatsApp chats, and sends a message when you ask. Link your phone to one of your devices, as you would WhatsApp Desktop."
  category: Connectors
---

WhatsApp is the user's WhatsApp accounts, each a phone linked as WhatsApp Desktop is linked, held on one of their
devices. `accounts` lists them; the other tools take `account`, the first by default.

- `chats` lists recent chats, `read` reads one, newest last, and `search` finds messages in every chat or one.
  Each pages back with `limit` and `skip`. They read what the link has kept, so they answer even when the device
  holding it is off. Reading never tells WhatsApp a message was read.
- `send` sends a real message to a real person, and can't be taken back: send only what the user asked to send, to
  whom they asked, with the exact text they approved. It needs the device holding the link to be up.
- `sign_in` links an account: it gives a QR code for the user to scan on their phone (WhatsApp > Settings > Linked
  devices > Link a device), or with `phone`, a code to type there instead. The user does this; never pretend to.
  `pairing` then says whether it linked, or the codes ran out first. Chats arrive over the next few minutes.
- `status` says whether each account is connected, and why not. `move` moves a link to another device that runs
  WhatsApp (`devices` lists them) without linking again, even when the one it's on is off. `sign_out` unlinks one
  and deletes its messages: only when the user asks.

A device runs WhatsApp once its service is installed there: `install_service --app whatsapp --service
WhatsApp.Link --server <key>`. It needs Go to build the link. The link's session is kept encrypted under a key in
the user's Vault, so a server must be chosen to open their Vault (`vault_grant`) before a phone can be linked.
