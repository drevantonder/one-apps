---
name: screen-sharing
description: Read before using a person's own Mac's screen through Computer Use, or when a Mac's screen says macOS doesn't allow Screen Recording or Accessibility.
metadata:
  title: "Screen Sharing"
  subtitle: "Your AI uses your Mac's screen"
  about: "Lets your AI see your Mac's screen and use its mouse and keyboard, as you would, through Computer Use, while you watch. Only you, and your network's owner, can use your Mac's screen."
  category: Agent tools
---

Screen Sharing makes each Mac running its service a screen in Computer Use, called what the Mac is called. Use it
with Computer Use's tools (`screens`, `screenshot`, `click`, `type`, `key`...), never its own `screen` tool:
Computer Use is where the Mac's person sees what you're doing, from each action's `doing`. `macs` says which Macs
you may use and whether macOS allows it yet, and asks macOS nothing.

- It's the Mac's main display, the one with the menu bar, with everything on it, signed in as its person. You act as
  them, so do only what they asked, and never sign in, buy, send or delete without them asking for that.
- Never type a password or a code (a one-time code, a passkey's PIN). Ask the person to type it on the Mac. `type`
  refuses while a password field has the focus.
- A screenshot is the display scaled down to what a model sees unshrunk (at most 1568 pixels on its long side and about 1.15
  megapixels), and x and y are its pixels. On a large display text is small: zoom in the app you're using (⌘+ in a
  browser) rather than guessing.
- Keys are named as xdotool names them. `ctrl` with a letter, digit or punctuation is ⌘, as a shortcut means on a Mac
  (`ctrl+l`, `ctrl+c`, `ctrl+t`), and with anything else ⌃ (`ctrl+Tab`). `super`, `cmd` and `meta` are ⌘, `alt` is
  ⌥, and `control` is always ⌃ (`control+c` in Terminal).

Only the Mac's person, the user its server is for, and the network's owner may use its screen; it's no one else's
screen. A Mac has Screen Sharing once its service is installed there: `install_service --app screen-sharing --service
ScreenSharing.Helper --server <key>`. The Mac needs Xcode or its Command Line Tools, to build the small app the
service runs there, Screen Sharing for The One App.

macOS lets that app see the screen only with Screen Recording, and use the mouse and keyboard only with
Accessibility, which only the Mac's person can allow. The first time an action needs one, macOS asks them on the Mac
and the action says what's missing. They allow it in System Settings → Privacy & Security → Screen & System Audio
Recording, and → Accessibility, by turning on Screen Sharing for The One App in each. macOS keeps that through the
server's updates; it asks again when the app's own source changes, and now and then for Screen Recording, as it does
of every app that records the screen.
