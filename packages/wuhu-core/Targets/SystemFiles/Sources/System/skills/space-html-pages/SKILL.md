---
name: space-html-pages
description: Author live HTML pages served from space files — read and write space data with the wuhu:space module, shell embedding, and /theme.css adoption.
---

# Live HTML pages in a Wuhu space

Hosted servers can advertise `contentHost` from `GET /v1/server`, a template such as `{group}--alex.wuhu.studio`. Replace `{group}` with the group's id and prepend `https://`; otherwise use `https://<group>.<contentBase>` as on self-hosted servers. `wuhu serve --content-host-pattern '{group}--alex.wuhu.studio' --origin https://alex.wuhu.studio` selects flat hosts, requires exactly one `{group}` at the start, requires any pattern port to match the origin, and is exclusive with `--group-certificate`.

Any HTML file in the space is a real page on its group's host. Discover it through `GET /v1/server`: use `https://` plus `contentHost` with `{group}` replaced by the group's id when advertised, otherwise `https://<group>.<contentBase>`. Write `/dash.html`, open it, done — no build step, native ESM only, and everything the page fetches must be same-origin.

## Data: `wuhu:space`

A page imports `wuhu:space`, the same module `run_script` has, with the same names, shapes and values. The server maps it into every HTML page; nothing to install. A file under `/_/conversations/*/attachments/` is message content, served sandboxed without it, so author pages elsewhere.

- `query` — one shot, resolves to an array of row objects. Bind values with a tagged template or `query(sql, params)`; never splice them into the SQL. Table names are quoted paths (`"/tasks.table"`); induced tables (`docs`, `links`, `sessions`, ...) work too.
- `observe` — live: an async iterable of whole snapshots, the current rows first, then new rows after every commit that changes them.
- `watch(glob, { from })` — live file events `{ kind: "write" | "delete" | "move", path, to?, rev, entry? }` after revision `from`; a delete has no `entry`. Fetch a file's content with a plain GET of its path. Without `from`, it starts at the current revision.
- `mutateRows(path, ops)` — `{ insert: {…} }`, `{ update: id, set: {…} }` (only the named fields) and `{ delete: id }`, all in one revision. Resolves to `{ rev, ids }`, the inserted row ids in order. An unknown column or a wrong type is an error.
- `readAttributes(path)` — a Markdown file's top-level frontmatter keys, `{ attributes, token }`.
- `patchAttributes(path, { set, remove, ifMatch })` — sets and removes top-level keys, keeping comments, key order, quoting and the body. `ifMatch` is the `token` you read; a stale one rejects with `code: "conflict"` and the current `token`.

```html
<ul id="done"></ul>
<script type="module">
  import { query, observe, mutateRows, readAttributes, patchAttributes } from "wuhu:space";
  const list = document.querySelector("#done");
  (async () => {
    for await (const rows of observe`SELECT title FROM "/tasks.table" WHERE status = ${"done"}`)
      list.replaceChildren(...rows.map((r) => Object.assign(document.createElement("li"), { textContent: r.title })));
  })();
  const { ids } = await mutateRows("/tasks.table", [{ insert: { title: "Ship page writes", status: "todo" } }]);
  await mutateRows("/tasks.table", [{ update: ids[0], set: { status: "done" } }]);
  const { token } = await readAttributes("/notes/plan.md");
  await patchAttributes("/notes/plan.md", { set: { status: "done" }, remove: ["draft"], ifMatch: token });
  console.log(await query`SELECT title, status FROM "/tasks.table" WHERE status = ${"done"}`);
</script>
```

Values: BOOLEAN columns are `true`/`false`, JSON columns the parsed value, BLOB a `Uint8Array`. An expression (`COUNT(*)`, `json_extract(...)`, `done OR 0`) has no declared type, so it comes back as SQLite's raw value.

Prefer `observe` over query-then-poll: its first snapshot replaces the initial query. A stream opens when the loop starts and closes when it leaves; a dropped connection reopens on its own. A refusal rejects with a `SpaceError` carrying `code`, `message` and sometimes `hint`; with the space unreachable, a one-shot call or write rejects with fetch's own `TypeError`.

A page acts as an ordinary member of the group it lives in, as the person viewing it. A hostless path means that group; `wuhu://<group>.localspace/<path>` reaches another group it can read or write. Admin-only targets (`shared`'s `/AGENTS.md` and skills, group settings) are refused. Writes are online only and never queued.

`/_/query` and `/_/observe` are deprecated: they still serve existing pages their old untyped `{columns, rows}` shape, but new pages use `wuhu:space`.

## Shell embedding

The server injects `/_/shell.js` into every HTML page. It is an ES module: import it directly when a page uses its API (the module map dedupes the import against the injected tag), or read the `window.wuhu` global it also sets for inline scripts:

```html
<script type="module">
  import { context } from "/_/shell.js";
  const current = await context;
  if (current.mode === "shell") {
    console.log(current.access, current.insets);
  }
</script>
```

`wuhu.context` resolves to `{mode:"raw"}` in a standalone tab. In a shell it resolves from the `wuhu:ready` / `wuhu:context` handshake with `mode:"shell"`, `access:"member"` (the viewer writes as a member of the page's group), and live total insets (device safe area plus chrome). There is one shell contract and two shells behind it — the web app embeds the page in an iframe, the native app hosts it in a web view — and a page never has to tell them apart. `shellOrigin` is the web shell's transport detail and is absent natively, so branch on `mode`, never on it.

The SDK writes the insets to the document root as `--wuhu-inset-top`, `--wuhu-inset-left`, `--wuhu-inset-right`, and `--wuhu-inset-bottom`. Every host sends device safe area plus chrome; the SDK writes those totals as plain pixels without adding `env()`. Bottom includes device safe area plus Dock, not keyboard height: WebKit owns keyboard avoidance. The SDK also sets root scroll-padding from these same four variables, so focus reveal and scrollIntoView avoid shell chrome without changing layout width. Native obscuredContentInsets stay zero; page CSS still owns content padding and fixed/sticky offsets. CSS edges are physical left/right, including RTL. Do not add keyboard height or another safe area in page CSS. The fallback below applies only in a raw browser tab, where the shell variables are absent. Paint the background to the edge, pad content by the insets, and add no additional safe area:

Put shell insets on the outer full-width element, then center a max-width column inside the remaining space. The column gets only its own gutters, never shell side insets:

```html
<body>
  <main class="page">Page content</main>
</body>
```

```css
body {
  margin: 0;
  padding: 0 var(--wuhu-inset-right, env(safe-area-inset-right, 0px))
    0 var(--wuhu-inset-left, env(safe-area-inset-left, 0px));
  padding-top: var(--wuhu-inset-top, env(safe-area-inset-top, 0px));
  padding-bottom: var(--wuhu-inset-bottom, env(safe-area-inset-bottom, 0px));
}
.page {
  box-sizing: border-box;
  width: 100%;
  max-width: 72rem;
  margin: 0 auto;
  padding: 24px;
}
```

Do not add `--wuhu-inset-left` or `--wuhu-inset-right` to a `max-width` column's padding. With `margin: auto` and `border-box`, that centers the column in the whole window and then shifts its content within the column instead of centering it beside the docked sidebar.

Inside a shell, ordinary same-origin link clicks are sent to shell history as `{type:"wuhu:navigate", path}`, where `path` carries the query and fragment too. The shell decides whether the destination is markdown, a data view, or another embedded page. Standalone links remain raw. This contract covers link clicks only; do not expect History API calls inside a page to drive shell navigation.

## Adopting the space theme

Link the space theme and use its tokens with fallbacks so the page matches the rest of the space and stays legible without a theme:

```html
<link rel="stylesheet" href="/theme.css">
<body class="wuhu-content">
<style>
  body { background: var(--bg, light-dark(#fff, #111)); color: var(--fg, light-dark(#1c1c1e, #e6e6e8)); }
</style>
```

Add `<meta name="color-scheme" content="light dark">` and keep every token `var()` fallback in `light-dark()` form. Tokens: `--bg`, `--fg`, `--fg-muted`, `--accent`, `--border`, `--code-bg`, `--font-text`, `--font-mono`, `--font-size`, `--content-width`, `--radius`, `--selection`.

## Sharp edges

- The page runs on the web origin; the API origin (`/v1/...`) is a different origin and not for pages. Stay on `wuhu:space` and the bundled `/_/shell.js` SDK.
- A page writes table rows and frontmatter only. Files, conversations, sessions, secrets and machines stay with sessions and the CLI.
- Shell insets report overlap; a page may intentionally ignore them for full-bleed content.
- The native shell opens a document by its space path and carries the query and fragment as that page's own URL state. A fragment naming a heading inside rendered markdown is kept but not yet scrolled to.
- The native shell refuses a download link and sends a link off the content origin to the system browser; neither reaches the page as an event.
- A directory serves `index.html` then `index.md`, and falls back to a generated listing of its entries. Under `/_/`, session homes (`/_/sessions/<id>/page.html`) and attachments serve as files; every other `/_/` name is reserved.
