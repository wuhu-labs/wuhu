# CanvasDocument

One `.canvas` board as a Loro doc, and its faces: the typed model and editor the native app draws and edits, and the canonical text agents read and write (`LiveFormat.canvas`).

## Layout

- `tree`: a movable tree with fractional index. A node is a top-level item, a section, or an item in a section; sections are one level deep. Sibling order is paint order, and sections paint beneath non-section items.
- A node's meta map: `id` (6 base-36 characters, unique in the board; agents and connectors use it, never the TreeID), `kind` (`sticky`, `text`, `rect`, `ellipse`, `diamond`, `section`, `file`), `x`/`y` relative to the parent section (the board at top level), `w`/`h` always stored, `color` (`yellow`, `pink`, `green`, `blue`, `purple`, `gray`, `white`; free text has none), `text` (a Loro text with `.wmd`'s marks; a section's title), `blocks` (`sticky` only: a movable list of `.wmd` block maps, see WmdDocument's schema), `path` (`file` only, a space path; readers ignore it on any other kind, and `setKind` away from `file` deletes it).
- `connectors`: a map id → map with `from`/`to` item ids, optional `fromSide`/`toSide` (`top`, `right`, `bottom`, `left`; absent is auto), `style` (`straight`, `elbow`), `offset` (a number: how far an elbow's middle segment sits from halfway between its ends; absent is 0), `arrow` (`none`, `end`, `both`; default `end`) and `label` (a Loro text).
- What falls outside the schema is skipped by readers and left alone by writers, except an item's `color` (none) or a connector field (`fromSide`, `toSide`, `style`, `offset`, `arrow`, `label`) out of schema, which reads as its default.

The agent view, as the `canvas` system skill teaches it:

```
- sticky {#a1k9z0 @40,60 160x160 yellow} Ship canvas **v1**
- sticky {#k4p2w8 @240,60 200x200 green}
  ## Launch

  - [ ] Draft the API
  - [x] Book the room
- text {#t7m2qq @40,300 320x40} Free text, line one
  continuation line two

## Sprint {#s3d8x1 @600,0 900x700 gray}
- rect {#b2c4v6 @640,60 200x100 blue} API draft
- file {#f9h1k2 @640,300 240x160} /designs/hero.png

# Connectors
a1k9z0 -> b2c4v6 {#c5n7r8 elbow right:left 40} "depends on"
```

Top-level items, then one `##` block per section, then `# Connectors`; coordinates absolute.

## Schema and model

`CanvasSchema` publishes the layout (`tree`, a movable tree with fractional index; `connectors`, a map id → map) and `configure`, which every board doc needs. `CanvasBoard(doc:)` reads a doc: items in tree order (top-level siblings, each section followed by its children), connectors by id. Whatever is outside the schema is skipped: an unknown kind, a node under a non-section, a section in a section, a repeated id, a connector to a missing item. Item `x`/`y` are relative to the section; `frame(of:)` is absolute.

A sticky says `note`: its `blocks` when it has them, else its `text` read as paragraphs, its lines running together and a blank line an empty paragraph, so it draws as it did. Every reader (agent view, apps, any board renderer) draws `note`; `text` and `blocks` are storage. An empty paragraph is a blank line someone typed: the agent view does not show it and an agent write leaves it in place, while an app writes exactly the blocks its editor shows. A sticky created by the apps, the server or an agent is stored as `blocks` (inserted text becomes paragraphs), so concurrent edits to it merge per character. There is no migration: a sticky stored as `text` keeps it until its first edit (an app's first keystroke, or an agent write that changes it) writes `blocks` and deletes `text`, so an untouched board never changes. An app or server that predates blocks shows every sticky stored as `blocks` empty, a new one included, and what it types into one goes to `text`, which every newer reader ignores. Two first edits of a sticky stored as `text` made at once keep only one side; so do two first edits of any other item that has no `text` container yet, which only an item made before every insert created one can lack. The web board draws a sticky's blocks read-only as plain lines (a list item behind `•`, `1.`, `☐` or `☑`, a heading as a plain line), duplicates one by copying its `blocks`, and edits only stickies stored as text; a sticky created on the web is stored as `text`.

## Editor

`CanvasEditor(doc)` issues operations in board terms (absolute frames, ids); the caller commits. It indexes the board when made: one per gesture or transaction. A delete takes a section's contents and every connector touching what it deleted. `setKind` away from `sticky` deletes `blocks`, as away from `file` it deletes `path`. Setters write only what differs, so a no-op edit makes no operation. An insert makes every item's container for its words, `blocks` for a sticky and `text` for anything but a file, even empty. A live editor writes each keystroke into the containers themselves: `containers(of:)` says where an item's words live now, and `blockList(_:)` hands a sticky's block list over, upgrading a sticky stored as `text`; `setText` and `setBlocks` sync a whole item at once. An app makes one editing session one Loro undo group, but Loro closes the group whenever it imports a peer's edit to the same words, so two people typing in turn in one sticky undo nearly keystroke by keystroke.

## Agent view and merge

`CanvasBoard.text` is the agent view: deterministic, coordinates rounded to whole points, item text in `.wmd`'s inline markdown with `{` escaped outside code, so a section title's attributes start at its first bare one. A sticky's `note` is `.wmd` block markdown (no frontmatter): one paragraph stays on the item line, anything more starts on the next line; later lines are indented 2 either way. The parser is strict and all-or-nothing: `CanvasSyntaxError` names the line and the problem.

A write diffs by id against the board the agent read. On an existing item an omitted attribute keeps its value, a sticky whose blocks read back as shown is not written (so it is not upgraded), and a position, size or connector offset that reads back as shown changes nothing, so an unrounded coordinate survives an unrelated edit and a child whose line is unchanged rides along with its moved section. A line under another heading reparents the item, keeping where it stood unless `@` says otherwise. A connector line says everything about its connector: what it omits is the default. Line order is paint order, applied with the fewest moves (those off a longest run already in order); top-level items and sections order among their own kind. A new item without `@` takes the next free grid slot (20-point gaps): inside its section below the title, else in rows below the whole board. New ids come from a generator seeded by the write's peer, so a write is deterministic. A connector whose line remains but whose end the write deleted goes too, with a note. Under `restoring`, an id the board no longer has is created with that id instead of refused.
