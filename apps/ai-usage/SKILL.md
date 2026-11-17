---
name: ai-usage
description: Read before choosing a model for heavy work, or when the user asks how much of an AI plan is left or whether it lasts to reset.
metadata:
  subtitle: "What's left of your AI plans"
  about: "See what's left of each AI plan, like Claude and Codex, and whether it lasts until it resets."
  category: AI
---

`status` is every AI plan's limits, in the providers' own words: what's left of each window (session, weekly,
monthly, and Claude's per-model ones), the pace against even use, and whether it lasts until it resets. Each
Claude account is apart, the one Claude Code is signed in to first, with which pool to spend. One switched off in
claude-swap says "not used" and isn't read; one that couldn't update keeps its last reading, with why and its age. A reading under 5 minutes old is
answered as it is; an older one is read again from every machine. `provider` narrows it to one, and `device` to
one machine.

Read it before long or heavy work, and spend the pool it says. A window "in deficit" is being used faster than
even; "Projected empty in 40 min" means it runs out before it resets.

A machine's plans are read once its service is installed there: `install_service --app ai-usage --service
AIUsage.Reader --server <key>`, on each machine its person signs in to Claude Code, Codex or OpenCode Go on. It
reads those tools' own sign-ins where they keep them, and never renews one: a sign-in that ran out renews the next
time its tool is used.
