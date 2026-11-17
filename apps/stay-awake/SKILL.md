---
name: stay-awake
description: Read when the user wants a Mac kept online with its lid shut, or asks why one went to sleep.
metadata:
  subtitle: "Keep a Mac online"
  about: "Keeps a Mac awake while it's plugged in, even with its lid shut, so your other devices and your AI can reach it. On battery it sleeps as usual."
  category: Devices
---

A Mac with Stay Awake on doesn't sleep while it's plugged in, even with its lid shut, so your other devices and
their agents can reach it; on battery it sleeps as usual. `set` turns it on or off for a Mac, and `status` says
whether it's keeping that Mac awake now. `macs` lists every Mac that has it. Give `device`, a Mac's name, to
choose one; without it, it's the first.

A Mac has Stay Awake once its service is installed there: `install_service --app stay-awake --service StayAwake.Mac
--server <key>`. Then it's on unless turned off.
