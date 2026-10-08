---
name: sessions
description: Create sessions from run_script with wuhu:session — a top-level agent for the humans, or several children in parallel whose reports wake you later — and retag, archive, unarchive, interrupt or resume yourself and your descendants.
---

# Creating and managing sessions

`run_script` reaches sessions through one module:

```js
import { createSession, request, setTags, archive, unarchive, interrupt, resume } from "wuhu:session"
```

- `createSession({ title, kind, topLevel, group, provider, model, effort, template, tags, message, expectsReply, key })` resolves to `{ id, requestId? }` as soon as the session exists. It takes what the `create_session` tool takes:
  - `kind` is `"task"` (the default) or `"agent"`. An agent has a box; a task answers only through `report`. An agent template, or `topLevel`, makes `"agent"` the default.
  - `topLevel: true` makes a root agent with no parent. Only an agent may create one, and `expectsReply` is refused: a root has nobody to report to. It belongs to the humans: it gives you no parent/ancestry control, but you retain the creator archive/unarchive exception below. `created_by` records you as its creator.
  - A child lives in your group. Only a top-level agent takes `group`: it lands in your group unless `group` names another one your group reads.
  - With `expectsReply` (and a `message`) the child starts on the message and owes you one final report. Without it, `message` arrives as a DM from you and nothing is owed.
  - Omitted `provider`, `model` and `effort` default to your own; a template's values win over that, explicit arguments over both.
  - `key` makes a retry safe: the same key from the same session returns the first session instead of creating a second. Without a key, every call creates.
  - If cloning the template or handing over the message fails after the session exists, it throws an `Error` whose `id` is the new session. It is not rolled back. A retry with the same `key` finishes what is missing, or throws the same way again.
- `request(id, message, { deadlineSeconds })` opens one request on a child of yours and resolves to `{ requestId }`. A child holds one open request at a time.
- `setTags(id, tags)` replaces the whole tag list, archived sessions included. `archive`, `unarchive`, `interrupt` and `resume` take a session id.
- `setTags`, `interrupt` and `resume` act on you and on your descendants — children, their children, and so on — and on nothing else. `archive` and `unarchive` also act on a session you created (a top-level agent included) and, when you are a top-level agent, on any session of your group, since that makes you its admin. A person archives or unarchives a session they created or any session of a group they administer. Each call is checked when it runs, so a script whose session has been archived meanwhile is refused.
- `archive(id)` archives the session and its whole descendant subtree, leaves first and root last; separately created top-level agents stay live. The default checks every node first (retired contractors are never busy, even with queued input) and refuses without archiving anything if any node is busy, naming all busy ids and titles. `archive(id, { force: true })` first interrupts busy nodes, then archives the subtree and closes all open requests with a final-kind “archived before reporting” message to each requester, including a requester outside the subtree. Rights on the root authorize its whole subtree. `unarchive(id)` restores only that one session.
- Force self-archive is always refused, even from a detached script. Without force, you cannot archive yourself mid-turn: the call keeps your session busy. A detached script that outlives the turn can archive it once it has settled, including its whole subtree when every node passes the default busy check. Your parent, an ancestor or a human can archive you instead.
- Renaming stays `set_title`, and only for yourself.
- A new session inherits nothing from you: its prompt carries the system `AGENTS.md`, the space-wide layer, its group's and its own home's, and it gets machine and repository context on touch. Put everything it needs in the brief, or in a template.
- The tree is at most 16 levels deep; creating below that is refused. A child cannot be created below a parent reserved for archive or already archived, including by a detached script.

A report never reaches the script. It arrives later as an ordinary message in your DM with the child, and it wakes you. So a script creates and returns; it never waits for a child's work.

## A top-level agent for the humans, with a brief

```js
import { createSession } from "wuhu:session"

const { id } = await createSession({
  title: "Ops",
  kind: "agent",
  topLevel: true,
  provider: "claude",
  model: "claude-opus-5-5[1m]",
  key: "ops",
  message: [
    "You are Ops. You own the build server and the nightly backups.",
    "Read /ops/README.md first. Post outages in your box.",
  ].join("\n"),
})
result(id)
```

The agent appears in the humans' roster as a root session. The brief waits for it in its DM with you. Tell the person who asked for it its id; it is not your descendant, so you cannot retag or interrupt it. You retain creator archive/unarchive rights, and a top-level agent also has archive/unarchive rights in its own group; the human’s rights are unchanged.

## Three researchers in parallel, then wait for their reports

```js
import { createSession } from "wuhu:session"

const topics = ["pricing of hosted agent workspaces", "Claude Code's MCP limits", "SQLite WAL on APFS"]
const children = await Promise.all(topics.map((topic, n) => createSession({
  title: `Research: ${topic}`,
  expectsReply: true,
  tags: ["research"],
  key: `research-${n}`,
  message: `Research ${topic}. Report your findings with sources in one final report.`,
})))
result(children.map(({ id, requestId }) => ({ id, requestId })))
```

Then end your turn. Each child's final report arrives as a message and wakes you; answer once all three are in. Never poll the children, never arm a timer to wait for them, never keep the script alive for them.
