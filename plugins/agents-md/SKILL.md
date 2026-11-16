---
name: agents-md
description: Read before reading or changing the instructions (AGENTS.md, CLAUDE.md) or skills every agent on every device gets.
---

`get` and `set` read and replace the AGENTS.md every agent tool on every device gets (Claude Code as its
CLAUDE.md, Codex, Amp, OpenCode). Skills live in every agent tool's skills folder: `skills` lists them, `skill`
reads one, `skill_set` adds or replaces one (all its files), `skill_remove` removes one. `history` lists
AGENTS.md's revisions (or a skill's), and `restore` brings an old one back. Check with the person before `set`,
`skill_remove` and `restore`, which change every agent's instructions at once.

A device gets them once AGENTS.md's service is installed there: `install_service --plugin agents-md --service
AgentsMd.Writer --server <key>`. It writes them as it starts, when they change, and every minute, into the home
folder of the user that device's server runs as, and they're whoever's that server is for. A file edited on
the device is left as it is.
