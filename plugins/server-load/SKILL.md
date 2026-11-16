---
name: server-load
description: Read when the user asks how busy their devices are, or before giving a device heavy work, to pick one with room for a desktop, a model or a build.
metadata:
  subtitle: "How busy your devices are"
  about: "See each device's memory, CPU, GPU and disk at a glance, with a widget for your Home Screen. Your AI uses it to pick a device with room for heavy work."
---

Server Load says how busy each device is; people see it as the app Device Activity and its widget. `now` lists
every device that's measured, on or not, with its memory (as Activity Monitor counts it on a Mac), CPU, GPU and
disk, its CPU and GPU over the last two minutes, and the containers it hosts. Use it before giving a device heavy
work, to pick the one with most to spare. A device that's off says when it was last seen.

Each device is measured by Server Load's service `ServerLoad.Meter`, which brings a small program written in Rust
and builds it on the device, so the device needs `rustc`. `services` says which servers run it, and
`install_service --plugin server-load --service ServerLoad.Meter --server <key>` runs it on one.
