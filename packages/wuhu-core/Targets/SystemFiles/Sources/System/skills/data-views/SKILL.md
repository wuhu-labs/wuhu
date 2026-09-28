---
name: data-views
description: Author *.view documents — JSON pairing a SELECT with a view kind (kanban in v1) that the web app renders as a live, auto-updating board.
---

# Data views

A data view is a document, not a feature: a `*.view` file holding one JSON object. The web app renders it as a live board; every table mutation that changes the query result re-renders it, and editing the `.view` file itself reloads the open view.

## Schema (v1: kanban)

```json
{
  "sql": "SELECT status, title, priority FROM \"/tasks.table\"",
  "view": "kanban",
  "config": { "groupBy": "status", "cardTitle": "title", "sort": "priority" }
}
```

- `sql` — a SELECT (query-sandbox rules: SELECT-only, quoted table paths, induced tables allowed). Select every column the config names.
- `view` — the discriminator; `"kanban"` is the only kind in v1.
- `config.groupBy` — the lane column; lanes appear in first-seen row order, NULL groups into an unnamed lane.
- `config.cardTitle` — the card text column.
- `config.sort` (optional) — orders cards inside a lane; numeric when both cells are numbers, otherwise lexicographic.

## Authoring workflow

1. Get the query right first: run the SELECT with the query tool and check the columns you need are present.
2. Write `/boards/tasks.view` with the JSON object. The file serves as `application/json`; humans open it in the web app and see the board.
3. Iterate by editing the file — the open view hot-reloads.

v1 boards are read-only: no drag, no mutations from the board. To change a card, mutate the underlying table and watch the board follow.

## Theming

Bundled providers link `/theme.css` and consume the theme tokens (`--bg`, `--fg`, `--accent`, `--border`, ...) with light/dark fallbacks, so a themed space themes its boards for free.
