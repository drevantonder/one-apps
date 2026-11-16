---
name: device-activity
description: Read when the user asks how busy their devices are, or before picking a device with room for a desktop, a model or a build.
---

`list` shows every one of your devices that's measured, on or not, with its memory (as Activity Monitor counts
it on a Mac), CPU, GPU and disk, and the containers each hosts after it. Use it to pick a device with room for a
desktop, a model or a build; `history` adds each device's last two minutes of CPU and GPU.

A device is measured once Load's meter is installed there: `install_service --plugin load --service Load.Meter
--server <key>`. Load's own `now` gives the same as numbers, by each server's key.
