---
name: space-scripts
description: Use wuhu:space in run_script — tables, files, search, revisions, groups and channels; conversation reading is in read-box.
script_exports: {"wuhu:space":["addChannelMembers","alterTable","checkout","context","createChannel","createGroup","createTable","find","grep","groups","history","identity","instantiateTemplate","list","move","mutateRows","observe","patchAttributes","query","readAttributes","readBytes","readText","remove","removeChannelMembers","renameChannel","stat","tableSchema","watch","writeBytes","writeText"]}
---

# Space scripts

Import named exports from `wuhu:space`. For `conversation` and `dm`, read [read-box](wuhu://system/skills/read-box/SKILL.md); their contracts live there.

Paths are in your group or a readable group's `wuhu://<group>.localspace/<path>`. System paths are read-only; machine paths are unavailable here. Writes refuse another session's home. Failures are `SpaceError` with `code`, `message` and `hint`; stale guards raise `conflict` with the current token. Unsupported options raise `invalidArgument`.

## Queries and subscriptions

- `query` accepts a tagged SQL template (interpolations become bound parameters) or `(sql, params)`, and resolves to row objects over the same tables as the query tool. JSON columns are parsed; blobs are Uint8Array.
- `observe` takes the same arguments and yields rows now and whenever the result changes, as an async iterable.
- `watch(glob, { from? })` yields file events `{ kind: "write" | "delete" | "move", path, to?, rev, entry? }`, starting at a revision when given.

Leaving either subscription loop closes it.

## Tables

- `createTable(path, { columns: [{ name, type }] })` creates atomically and resolves to `{ rev, token }`. Types are `string | integer | number | boolean | json`. The auto-assigned `id` is implicit and reserved; columns are ordered.
- `tableSchema(path, { rev? })` resolves to `{ header, token }`. A historical token is not a current overwrite receipt.
- `alterTable(path, header, { ifMatch, allowDropColumns? })` replaces the whole header at the required current token. Dropping columns requires `allowDropColumns: true`; changing types is refused.
- `mutateRows(path, [{ insert: { col: value } } | { update: id, set: { col: value } } | { delete: id }])` applies operations in one revision and resolves to `{ rev, ids }`, with ids for inserted rows.

Headers have at most 256 columns; names are nonempty, case-insensitively unique, at most 256 UTF-8 bytes and contain no controls.

```js
import { createTable, mutateRows, tableSchema, alterTable, query } from "wuhu:space"
const path = `/_/sessions/${import.meta.session}/reading.table`
await createTable(path, { columns: [{ name: "title", type: "string" }] })
await mutateRows(path, [{ insert: { title: "The Left Hand of Darkness" } }])
const { header, token } = await tableSchema(path)
await alterTable(path, { columns: [...header.columns, { name: "read", type: "boolean" }] }, { ifMatch: token })
result(await query(`SELECT * FROM "${path}"`))
```

## Files and revisions

- `readBytes(path, { rev? })` returns `{ data: Uint8Array, token, rev }`; `readText` returns `{ content: string, token, rev }`. Each file is capped at 16 MiB and counts against script buffers.
- `writeBytes(path, data, { ifMatch })` and `writeText(path, content, { ifMatch })` require null for atomic create-only or the current string token for replacement. They return `{ rev, token }` and refuse `.table` file writes.
- `stat(path)` returns entry metadata. `list(path, { rev?, hidden? })` returns `{ rev, entries }`, capped at 500 entries.
- `history(path, { after?, limit? })` returns ascending `{ entries, next }`, default 100/max 500. `next` is a revision cursor or null.
- `checkout(path, rev, { ifMatch })` restores history at the current token (null restores an absent path).
- `move(from, to, { replace? })` and `remove(path, { ifMatch? })` mutate files including tables. An existing destination is refused unless `replace: true`, which replaces in the same revision. Alias one `remove` import if also importing `wuhu:secret`.
- `readAttributes(path)` returns Markdown frontmatter `{ attributes, token }`. `patchAttributes(path, { set, remove, ifMatch })` sets/removes top-level keys, preserves the remaining YAML and returns `{ token }`.

## Search

`find(glob, { path?, limit?, hidden?, noIgnore?, step? })` returns `{ paths, step, scanned, skipped }`; `grep(pattern, options)` returns `{ matches: [{ path, line, text }], step, scanned, skipped }`. They use the tools' glob/ICU regex rules and traversal. `limit` corresponds to tool `matchLimit`, default 50/max 1000. Skips are `{ reason, count, example }`, one per reason. A non-null `step` resumes the scan; null means done. Search accepts readable space and system paths, not machine paths.

## Discovery and groups

- `context()` returns `{ session, group, contentHost }` for the caller.
- `groups()` returns live `{ id, member, readable, admin }` entries.
- `createGroup({ alias, owner })` returns `{ id, alias }` for a new open group. The owner is a live non-guest human account id, persona id or person alias, and becomes admin; the creating session does not. Alias naming follows the shared group-address rules.
- `identity()` returns resolved `{ defaultIssuer, overrides, issuerFor(origin) }` for verifier trust, read-only.

## Channels

`createChannel({ title?, people })` returns a human-only channel id in your group. `addChannelMembers(id, people)`, `removeChannelMembers(id, people)` and `renameChannel(id, title)` manage it; a null title shows members' names. People may be canonical directory ids or person aliases (case-insensitive, including historical aliases); create/add store canonical ids; remove deletes both the supplied spelling and its canonical id, including legacy alias rows, and an unknown nonmember is a no-op. Unknown people on create/add and session membership throw `SpaceError` with `code: "invalidArgument"`. Read-box owns conversation visibility.

## Templates

A template is a markdown file whose frontmatter has a `template` attribute. `instantiateTemplate(template, { in? })` from `wuhu:space` in `run_script` (or `wuhu new <template> [in]`, the CLI’s HTTP `new` verb) instantiates it next to the template unless a destination is given; the module resolves `{ path }`, and the CLI prints the path. Exactly two strategies exist — do not invent other conventions:

- `template: {"strategy":"incr","prefix":"TASK","pad":3}` — sequential `TASK-001.md`, `TASK-002.md`, ... (prefix uppercase ASCII; pad = minimum digit width).
- `template: {"strategy":"date","folders":false,"specificity":"minute"}` — local-time date names, `2026-07-06.md` (nested `2026/07/06.md` with folders; `-HH-MM` appended at minute specificity).

The instance keeps the template's content minus the `template` key.
