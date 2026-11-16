---
name: server-load
description: Read when the user asks how busy their devices are, or before giving a device heavy work, to pick one with room for a desktop, a model or a build.
---

Server Load says how busy each device is; people see it as the app Device Activity and its widget. `now` lists
every device that's measured, on or not, with its memory (as Activity Monitor counts it on a Mac), CPU, GPU and
disk, and the containers each hosts after it. Use it before giving a device heavy work, to pick the one with most to
spare; `history` adds each device's last two minutes of CPU and GPU, and `format: json` gives every figure as a
number with each device's server key. A device that's off says when it was last seen.

Each device is measured by Server Load's service `ServerLoad.Meter`, which brings a small program written in Rust
and builds it on the device, so the device needs `rustc`. `services` says which servers run it, and
`install_service --plugin server-load --service ServerLoad.Meter --server <key>` runs it on one.
