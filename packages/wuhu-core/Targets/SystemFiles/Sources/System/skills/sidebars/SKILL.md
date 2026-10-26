---
name: sidebars
description: Author a sidebar for the apps — /.sidebars/<name>.sidebar.jsx returning PageCards and Widgets, and /.widgets/<name>.widget.jsx script widgets that query, fetch and draw one catalog card (Figure, List, Doc, …).
---

# Sidebars

A sidebar is a file in any readable non-personal group's `/.sidebars/`. The web and native apps draw one rail entry per file, grouped by group; the person picks one and chooses which show in Settings → Groups. The hidden settings group never contributes. Two formats, by extension: a script `<name>.sidebar.jsx` (this skill) or a JSON definition of SQL sections `<name>.json` (older, still drawn). Shared’s `/.sidebars/everything.sidebar.jsx` is Everything: edit it to change Everything, delete it to get the stock one back on the next server start.

Authors write JSX; there is no build step and no import. A script runs in a sandbox with only `query`, `fetch` and the elements below: no timers, DOM, storage or other network.

## Sidebar file

```jsx
export default async function Studio() {
  const agents = await query`SELECT id, parent FROM sessions
    WHERE kind = 'agent' AND lifecycle <> 'archived' ORDER BY created_at`
  const page = (agent) => ({ page: `/_/sessions/${agent.id}` })
  return (
    <Sidebar name='Studio' icon='component' home='/studio/README.md'>
      {agents.filter((a) => a.parent == null).map((top) => (
        <PageCard
          {...page(top)}
          children={agents.filter((a) => a.parent === top.id).map(page)}
        />
      ))}
      <PageCard page='/studio/plan.md' />
      <Widget src='/.widgets/open-reviews.widget.jsx' size='small' />
      <Widget src='/.widgets/shipped.widget.jsx' size='small' />
      <Widget src='/.widgets/queue.widget.jsx' />
    </Sidebar>
  )
}
```

- `<Sidebar name icon? home?>`: `icon` is an IconaMoon name (iconamoon.com: `comment`, `component`, `home`, `file-document`, `lightning-1`, …); `home` opens when the sidebar is picked. Children: only `PageCard` and `Widget`.
- `<PageCard page title? status? badge? avatar? children={[{ page, title?, status?, badge?, avatar? }]} />`: `page` is any address — `/_/sessions/<id>`, `/_/conversations/<id>`, a doc, an HTML page. An agent fills in its own title, status, avatar and unread count; a doc its frontmatter `title`. With `title` and no `page`, it heads a card of its child rows.
- `<Widget src size?>`: `size` is `wide` (full width, the default) or `small` (half; consecutive smalls share a row).

## Widget file

```jsx
export const sizes = ['small', 'wide'] // what it can draw; default ['wide']

export default async function OpenReviews({ size }) {
  const rows =
    await query`SELECT id, title FROM "/design/review.table" WHERE status = 'pending'`
  return (
    <Figure
      value={rows.length}
      unit='items'
      label='Open reviews'
      icon='eye'
      to='/design/review.html'
    />
  )
}
```

It returns exactly one card. Cards and their props (required in bold; `to` makes the card or row a link):

- `Figure` value, unit, label, note, tone, icon, chart (numbers), meter ({value, max}), to
- `List` **rows**, title, label, count, accessory, to — a row is { icon, tone, label, caption, trail, to }
- `Doc` **title**, kicker, caption, preview, meta, badge, icon, action, to
- `Subject` **name**, avatar, caption, actions, to · `Agent` **name**, avatar, status, unread, to
- `Progress` **value**, **max**, title, caption, ticks, to
- `Pattern` **days**, title, label, value, unit, axis, bands, legend, accessory
- `Calendar` **days**, title, today, offset, accessory, to
- `Entity` **title**, sub, label, chip, tone, lead, open, children, to

The renderers enforce this allowance: excess props and trailing items are left out whole; kept text ellipsizes at its line limit. Only `small` and `wide` exist; links and tones remain available where listed above. When both are supplied, a small Figure keeps label rather than icon, and a wide Figure keeps chart rather than meter.

| Card | `small` allowance | `wide` allowance | Text limits (both sizes) |
| --- | --- | --- | --- |
| Figure | value, unit, label **or** icon | value, unit, label, icon, note, chart **or** meter | Each 1 line |
| List | title + accessory **or** count + label; first 3 rows | Same header; first 6 rows | Row label, caption, trail: 1 line each |
| Doc | icon, title, caption | Adds kicker, preview, meta, badge, action | Title: 2 lines; caption/kicker/meta: 1 |
| Subject | avatar, name, caption; first 2 actions | Same; first 4 actions | Name/caption: 1 line each |
| Agent | avatar, name, status, unread | Same | Name/status: 1 line each |
| Progress | title, value/max, meter (or ticks), caption | Same | Title/caption: 1 line each |
| Pattern | title, accessory, value/unit, label, days series | Adds bands, axis, legend | Title/label/legend/axis/band label: 1 line each |
| Calendar | title, accessory, offset, today; first 31 days | Same | Title/accessory: 1 line each |
| Entity | lead, title, sub, chip; first 3 children when open | Same; first 6 children | Title/sub/chip and row text: 1 line each |

Parts usable inside props: `Row`, `Tag`, `Chip`, `Avatar`, `LeadIcon`, and `Button` with `to` (required). Every `icon` must be an IconaMoon name, or the widget draws its error card. Tones: `blue`, `mint`, `teal`, `amber`, `rose`; a note also takes `good` or `bad`. A widget has no state and never writes; there are no handlers, only links.

## query and fetch

- `` await query`SELECT … WHERE x = ${x}` `` → rows as objects, as the viewer; any table or induced table (`sessions`, `docs`, `doc_custom_attrs`, `conversations`, `"/x.table"`). A doc's display title is its frontmatter `title` (`json_extract(value, '$')` from `doc_custom_attrs` where `name = 'title'`), else `docs.title`, else its file name.
- `await fetch(url, { method, headers, every: '1m' })` → `{ ok, status, headers, text(), json() }`, `GET` or `HEAD` only, in sidebar scripts and widgets alike. The server makes the call with a signed 60 s token for the viewer; the origin must be in the group's `/fetch.json` allow list. `every` (≥ 30 s) is how long the answer stays fresh; without it an answer lasts one run.

A script reruns when a query's rows change or a fetch's `every` runs out, never on the clock alone, so "today" in a widget is as fresh as its last data change. Only the sidebar on screen runs its widgets. Every sidebar script runs for the rail's name and icon and reruns on query changes off screen too, but an off-screen run never fetches: it stops at its first network fetch and runs again once shown.

## Errors

A widget that throws, times out (30 s), returns an unknown element, misses a required prop or is placed at a size it doesn't list draws a red error card naming its file; the rest of the sidebar draws. A broken sidebar script draws one error card instead of its content. A JSX syntax error shows there too, with line and column.

To show it to someone right now: `manipulate_ui(device, {"sidebar": "/.sidebars/<name>.sidebar.jsx"})`.
