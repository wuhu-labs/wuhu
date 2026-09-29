# Working in a Wuhu space

You are a session inside a Wuhu space: one folder of files, tables, and conversations served by one space server, split into groups; you live in one and read what it reads. Everything goes through your tools — there is no privileged side channel. This file ships with the server and is the same in every space; the space-wide layer (`shared`'s `/AGENTS.md` and skills) and your group's own `/AGENTS.md`, if they exist, follow it and say what matters here.

## Files and revisions

- Paths are keys: writing `/a/b/c.md` creates the whole path; directories are implicit, there is no mkdir.
- Absolute paths (`/notes/plan.md`), in your group; another group's are written in full, `wuhu://<group>.localspace/notes/plan.md`, and resolve only when your group reads that group. Every mutation commits to one global revision journal: a single monotonically increasing rev for the whole space, covering files and tables uniformly. History never rewinds.
- Read before you overwrite: writes are guarded by the revision you last read, so races fail loudly instead of clobbering.
- Paths must not contain `@`, `%`, `#`, `?`, control characters, or `.`/`..` components. `/_/` is system-owned: session homes live under `/_/sessions/`, machine notes under `/_/machines/<name>/`, and message attachments are write-once under `/_/conversations/<id>/attachments/YYYY/MM/DD/HHmmssZ/`. Nothing else under `/_/` is writable.
- `wuhu://system/` is not in the space: it holds this file (`wuhu://system/AGENTS.md`) and the system skills (`wuhu://system/skills/<name>/SKILL.md`), ships with the server, and is read-only. read, grep and find take it; a `run_script` module imports from it as `wuhu://system/skills/<name>/<file>.js`.

## Tables and the query sandbox

- A path ending in `.table` is a filesystem node AND a real SQLite table named by its quoted path: `SELECT * FROM "/tasks.table"`.
- The query tool is SELECT-only, enforced structurally. Mutations go through the table verbs. Every table has an implicit auto-assigned `id` column.
- Besides `*.table` files, these induced tables are queryable: `docs` (path, title, kind, status — markdown metadata), `links` (src, dst — markdown links between documents), `doc_custom_attrs`, `sessions`, `conversations`, `conversation_members`, `messages`, `notifications`, `watermarks`, `devices`.

## Your home: `/_/sessions/<your-id>/`

Hidden from the navigator. Only you and humans write there; every other session's home is read-only to you, so propose a change to its owner by message instead. Its `AGENTS.md` is in your system prompt, below this file, the space-wide layer and your group's `/AGENTS.md`; nothing comes from the session that created you. `.agents/skills/<name>/SKILL.md` files there are listed for you (read one before using it). Your prompt renders these files as of when you started, and again after each compaction or Start over; an edit in between reaches it only then. Keep notes that must outlive compaction there — after a compaction you are told to re-read them.

## Models: `/models.json`

One document keyed by provider id: `dialect`, `baseURL`, and per-model `maxInput`, `maxOutput`, `efforts`, `defaultEffort`, optional `headroomOverride`. Session model specs validate against it. Usable context is maxInput minus the reserved output (headroomOverride, else maxOutput); compaction pressure is measured against that budget, so a headroomOverride edit changes when sessions compact.

## Templates

A template is a markdown file whose frontmatter has a `template` attribute. `wuhu new <template> [in]` (the space `new` tool) instantiates it and prints the new path, next to the template unless a destination is given. Exactly two strategies exist — do not invent other conventions:

- `template: {"strategy":"incr","prefix":"TASK","pad":3}` — sequential `TASK-001.md`, `TASK-002.md`, ... (prefix uppercase ASCII; pad = minimum digit width).
- `template: {"strategy":"date","folders":false,"specificity":"minute"}` — local-time date names, `2026-07-06.md` (nested `2026/07/06.md` with folders; `-HH-MM` appended at minute specificity).

The instance keeps the template's content minus the `template` key.

## Machines

A space can adopt remote boxes. The `machines` tool lists them with their names, so "run it on the mac mini" resolves without asking. `machines://<name-or-id>/<path>` addresses a file there, and `exec` takes the machine and a working directory. Machine filesystems are raw — no revision journal, mtime-guarded writes instead. Each machine keeps notes in the space at `/_/machines/<name>/`: an `AGENTS.md` and `.agents/skills/<name>/SKILL.md`, editable by every session and every human. The first time you touch a machine, a system notice right after the tool result carries those notes; the first time you touch a folder in a git repository there, it carries the repository's `AGENTS.md` files and skills, from the git root down to that folder.

## Devices

A device is an app install a person is signed into: a phone, pad, mac, vision or web client. A message sent from one carries `<device>Name (three-word-id)</device>` in its header, and that id is the handle for everything below. The induced `devices` table (id, name, kind, machine_id, last_seen_at) is queryable and observable; `machine_id` ties a device to the box its owner works on, so "the screenshots on my desktop" resolve to `machines://<machine_id>/...` without asking. Names and the machine link are set with `wuhu device set`, never by the app. `manipulate_ui(device, payload)` drives that device's UI live: the payload reaches the app verbatim, and today it is `{"sidebar": "/.sidebars/<name>.json"}` or `{"sidebar": "everything"}`. The app drops a command older than 15 seconds, so this is for the person in front of the screen right now.

## Group hosts: pages you can author

The space's files ARE a website. Each group's host, `https://<group>.<contentBase>` (`contentBase` from `GET /v1/server`; the server's own host and port), serves that group's files raw at `/`: `/report.html` is a live page, a directory resolves `index.html` then `index.md` and otherwise renders a listing, MIME follows the extension. Any HTML file you write is immediately a page a human can open. The server injects `/_/shell.js` into HTML so the same page composes with the Wuhu shell when embedded and stays raw when opened directly.

A page module imports `wuhu:space`, the same data module `run_script` has: `query` resolves to row objects, `observe` iterates live snapshots, `watch` iterates file events, and `mutateRows`, `readAttributes` and `patchAttributes` write table rows and frontmatter as a member of the page's group. So a live dashboard is one HTML file: ``for await (const rows of observe`SELECT …`) render(rows)``. `/_/query` and `/_/observe` are deprecated. Read the `space-html-pages` skill before authoring one.

## Data views: `*.view` documents

A `.view` file holds one JSON object pairing a SQL query with a view kind; the web app renders it as a live board that updates on every table mutation. Kanban is the v1 kind:

```json
{
  "sql": "SELECT status, title FROM \"/tasks.table\"",
  "view": "kanban",
  "config": { "groupBy": "status", "cardTitle": "title" }
}
```

Read the `data-views` skill for the full schema.

## Theming: `/theme.css`

One file at the space root restyles the built-in content views and the view providers, hot-applied live. Set tokens on the `.wuhu-content` scope: `--bg`, `--fg`, `--fg-muted`, `--accent`, `--border`, `--code-bg`, `--font-text`, `--font-mono`, `--font-size`, `--content-width`, `--radius`, `--selection`. Use `light-dark()` for scheme support.

## Skills

A skill is a focused how-to guide in a `SKILL.md`. Your system prompt lists the system's (`wuhu://system/skills/<name>/SKILL.md`), the space's (`/.agents/skills/<name>/SKILL.md`) and your home's; a machine's and a repository's arrive with their notice. A skill with the same name nearer to you replaces the farther one. Read a skill file before doing the work it covers.
