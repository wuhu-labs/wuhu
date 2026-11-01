---
name: canvas
description: Read and change a *.canvas board — stickies, shapes, free text, file cards, sections and connectors — as text with the ordinary read, write and edit tools, even while people have it open live.
---

# Canvas boards

A `.canvas` file is a live whiteboard people draw on in the apps. You see it as text: `read` it, change the text, `edit` or `write` it back. Your write merges into the live board as edits made at the version you read, so people's concurrent changes survive and they watch yours land. There is no canvas tool and nothing to convert: never copy a board into another format.

## The text

```
- sticky {#a1k9z0 @40,60 160x160 yellow} Ship canvas **v1**
- text {#t7m2qq @40,300 320x40} Free text, line one
  continuation line two

## Sprint {#s3d8x1 @600,0 900x700 gray}
- rect {#b2c4v6 @640,60 200x100 blue} API draft
- file {#f9h1k2 @640,300 240x160} /designs/hero.png

# Connectors
a1k9z0 -> b2c4v6 {#c5n7r8 elbow right:left} "depends on"
```

- An item is `- <kind> {<attributes>} <text>`. Kinds: `sticky`, `text`, `rect`, `ellipse`, `diamond`, `file`. Text uses `.wmd` inline markdown (`**bold**`, `*italic*`, `[label](url)`); more lines continue indented 2 spaces. A `file` card's text is one space path.
- Attributes: `#id` (6 base-36 characters), `@x,y` (top-left, absolute, in points), `WxH`, and a colour: `yellow`, `pink`, `green`, `blue`, `purple`, `gray`. Free `text` has no colour.
- A section is a `## Title {…}` heading; the item lines under it are inside it. Sections don't nest. Top-level items come first, then the sections, then `# Connectors`.
- A connector is `from -> to {#id …} "label"` between item ids: `->` arrow at the end, `<->` both ends, `--` none. Optional `elbow` (default straight), `fromSide:toSide` (`top right bottom left auto`), an elbow offset (a number like `40` or `-20` that slides its middle segment), and a quoted label.
- Line order inside a block is paint order: later lines draw on top.

## Changing a board

- **Add**: write a line without `#id`. Everything in `{…}` is optional: without `@` it takes the next free slot in its section (or below the board), without a size the kind's default. `{}` may be dropped entirely: `- sticky Book the venue`.
- **Change**: edit the line in place; a field you drop keeps its value on an existing item. Changed text merges as text.
- **Move into a section**: put the line under that `##` heading. Moving a section's `@` moves everything in it.
- **Delete**: remove the line. A section takes its contents with it, and an item takes its connectors.
- **Connect**: a connector line names the two item ids. To connect an item you are adding in the same write, write it first, re-read for its id, then add the connector.

Every write is all-or-nothing: an unparseable line, a duplicate or unknown `#id` ("omit the id to create"), a connector to a missing id or a nested section refuses the whole write with the line and reason; fix that line and retry. The board comes back canonical (ids filled in, coordinates rounded, lines normalized), so re-read it before the next `edit`.
