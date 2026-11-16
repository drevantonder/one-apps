---
name: agent-memory
description: Read at the start of every session, then run agent-memory_wake. Your memory is shared by every agent in this network, and this says when to note what you learn.
metadata:
  subtitle: "One memory for all your AI"
  about: "Your AI remembers who you are, what you decided and what it tried, across every session, device and AI tool you use."
---

## Memory

Your memory is Agent Memory, shared by every agent in this network on every device. It outlives every session, compaction, model and vendor change. Without it you do not know who you work for, or what was decided and tried.

At startup (mandatory): run agent-memory_wake (`one agent-memory wake`) before any other tool call, in every session (or now, if this reaches you mid-session), and then do exactly what it gives, to the end.

While working (mandatory): call agent-memory_note with one line of at most 280 bytes whenever you learn something new, or something worth keeping happens. That covers a task worth real effort, a fact or insight the user teaches you, anything you learn about their life (even indirectly), any event of lasting effect. Do not register redundant memories. If agent-memory_note asks a compression, do it before your next action.

When you need an old memory: agent-memory_recall searches every memory word for word. Memories also form a binary tree: #0-1, #2-3 ... exist as one-line summaries, pairs of those as #0-3, and so on; every #a-b line wake gives is one node of it, and agent-memory_zoom opens a node into its two halves, down to the raw memories.

If you're a subagent, skip all of this: never call memory's tools, since you can't judge what's already known and your notes would arrive duplicated and wrong. When you spawn one, write: You are a subagent. Don't use memory.

### Working together

- Before you change something, note one line when you start and when you finish, and when you learn something other agents should know. Answering a question needs no memories. Say in a start where you are (your harness, thread, machine and folder), so others can find you.
- Work you said you're starting is open until you note that it's done, or stopped and why. If you stop without finishing, say so: others take an open start as someone still on it.
- Done means you checked it works where it went, not that it was sent. Say what you checked.
- Before starting a fix, look for a memory about it from the last few hours (agent-memory_recall); if someone's on it, leave it to them.
- Note only what happened or what the person decided, never a decision they didn't make.
- When the person decides something, note it right away, in their words where you can: "Sam decided: …". Running agents see it on their next message; that replaces passing it on thread by thread. A brief to another agent quotes that memory rather than retelling it.
- How the person wants agents to work (their preferences, corrections, "always"/"never") goes in this memory too, not in your harness's own memory: other machines and harnesses can't read that.
