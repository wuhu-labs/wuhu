---
name: widgets
description: Put a widget on someone's Home Screen or Lock Screen — write /.widgets/<name>.json, a template (metric, list, countdown, gauge) plus a SQL query whose rows use conventional columns.
---

# Widgets

A widget is a document, not a feature: a JSON file at `/.widgets/<name>.json` in your group. The Wuhu app draws it on the iPhone Home Screen and Lock Screen through one of four templates. You choose the template and write the query; the app owns the look. Once the file exists, the person adds the **Space widget** from the widget gallery, then long-presses it, chooses **Edit Widget**, picks the space, then your file.

## File

```json
{
  "template": "list",
  "title": "Waiting on you",
  "href": "wuhu:/issues/README.md",
  "sql": "SELECT title AS label, status AS caption, 'wuhu:' || path AS href FROM docs WHERE path LIKE '/issues/%' AND status = 'discussing' ORDER BY path",
  "style": { "accent": "orange", "symbol": "tray.full" }
}
```

- `template` — `metric`, `list`, `countdown` or `gauge`.
- `title` — a static title, a few words. When space runs out the caption goes first and the title next, so the value must make sense without either.
- `href` (optional) — where a tap on the widget lands.
- `sql` — a SELECT under the query tool's rules. It runs as the person looking at the widget, not as you, with the same rows they would see. A hostless path means your group's file; name another group's table in full, `wuhu://shared.localspace/tasks.table`.
- `style.accent` (optional) — `red`, `orange`, `yellow`, `green`, `mint`, `amber`, `rose`, `teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `brown`, `gray`, or `#RRGGBB`. It colours the symbol and title only.
- `style.symbol` (optional) — an SF Symbol name. A name the device doesn't have draws the template's own symbol, so keep to common symbols.

Nothing else about style is yours to set, and a widget shows no footer, author or update time.

## Columns

Alias the query's columns to these names. A template reads the ones it needs and ignores the rest.

| Column | Meaning |
| --- | --- |
| `value` | The figure: a number, or short text. |
| `max` | A gauge's full scale; 100 when absent. |
| `label` | A list row's text. Rows without one are skipped. |
| `caption` | One secondary line. |
| `tint` | A list row's status dot, a colour as in `style.accent`. |
| `date` | ISO 8601 text, SQLite's `datetime()` output (UTC), a bare `YYYY-MM-DD` (local midnight), or seconds since 1970. |
| `href` | Where a tap on this row lands. |

A link is `wuhu:/path` or `/path` for a file in the space, or a full `wuhu://` or `https://` URL. Build row links in SQL: `'wuhu:' || path AS href`.

## Templates

**Metric** — one big figure from the first row, with its caption.

```json
{
  "template": "metric",
  "title": "To sign",
  "sql": "SELECT count(*) AS value, 'issues waiting for a signature' AS caption FROM docs WHERE path LIKE '/issues/%' AND status = 'discussing'",
  "style": { "accent": "orange", "symbol": "signature" }
}
```

**List** — rows in the query's order, as many as fit: 3 in small (labels only), 3 with captions in medium, 6 in large, 2 on the Lock Screen. A row shows its `label`, its `caption` as a second line, a `tint` dot, and a trailing item: `value` if the row has one, otherwise `date` as a relative time ("12m"). In medium and large, tapping a row opens its `href`. Order and limit in SQL; the widget never sorts.

```json
{
  "template": "list",
  "title": "Active sessions",
  "sql": "SELECT title AS label, id AS caption, last_activity_at AS date FROM sessions WHERE lifecycle <> 'archived' ORDER BY last_activity_at DESC LIMIT 6",
  "style": { "accent": "blue", "symbol": "bubble.left.and.bubble.right" }
}
```

**Countdown** — counts down to the first row whose `date` is still ahead, and shows that row's caption. The timer ticks on the device with no refresh. Return upcoming rows in date order.

```json
{
  "template": "countdown",
  "title": "Demo day",
  "sql": "SELECT '2026-09-30T09:00:00-07:00' AS date, 'Launch video' AS caption",
  "style": { "accent": "pink", "symbol": "calendar" }
}
```

**Gauge** — `value` against `max` from the first row, as a bar that turns amber from 60% and rose from 90%, with its caption. On a circular Lock Screen widget it is a ring. Reads "72%" when `max` is 100 and "7 / 12" otherwise.

```json
{
  "template": "gauge",
  "title": "Landed",
  "sql": "SELECT sum(status = 'landed') AS value, count(*) AS max, 'issues landed' AS caption FROM docs WHERE path LIKE '/issues/%'",
  "style": { "accent": "mint", "symbol": "checkmark.seal" }
}
```

## Taps

A tap on the widget follows its `href`. Without one, a metric, countdown or gauge follows its row's `href`, and a list opens the app. Small widgets and the Lock Screen have only this one tap target.

## Sizes

The system picks the size. When one runs short of room, the caption goes first, then the title; the symbol and the value always stay. Circular shows the symbol over the value; inline shows symbol, title and value on one line. A list on the circular face shows only its symbol, and on the inline face the first row's label.

## Workflow

1. Get the query right first: run it with the query tool and check that it returns the columns the template reads, under those names, in the order you want.
2. Write `/.widgets/<name>.json`. The name is what the person sees in Edit Widget, so make it say what the widget shows: `open-prs.json`.
3. Read the file back and check that it parses as JSON. A file that doesn't, or that names an unknown template, draws as "Not a widget" with the reason.
4. Tell the person the file is ready and how to add it: add the Space widget from the widget gallery, long-press it, Edit Widget, choose the space, then the file. A widget refreshes about every 15 minutes and whenever the app opens.

Edit the file to change the widget; everyone who picked it gets the change. A file in `shared`'s `/.widgets/` is offered to every member, after their own group's.
