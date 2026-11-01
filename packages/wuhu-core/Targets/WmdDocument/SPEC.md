# WmdDocument

One `.wmd` document as a Loro doc, and its two faces: the live doc clients edit and the canonical markdown agents read and write. Loro enters as the `Loro` SwiftPM product on Apple and as `@loro_swift//:LoroLinux` (an http_archive of the loro-swift sources over a prebuilt Linux FFI) on Linux.

## Document schema

- `frontmatter`: a map, key → JSON value.
- `blocks`: a movable list of maps. `kind` is `h1` `h2` `h3` `paragraph` `code` `list` or `view`. A `list` block has `level` (0…; a double written by the web reads as its integer) and `style` (`unordered` `ordered` `todo` `done`). Every kind but `view` has a `text` container; `view` has `view`, `sql` and a `config` map instead.
- Marks on `text`: `bold`, `italic` (expand after) and `link` (a URL, expand none). `code` text carries newlines and no marks.

## Markdown

The agent view parses the `.wmd` subset and renders it back canonically: frontmatter keys sorted, one blank line between blocks except between consecutive list items, ordered lists renumbered, a view block as a ```` ```wuhu-view ```` fence holding `{"view","config","sql"}` with sorted keys. A list item's later lines sit 4 spaces past its marker; blank lines between them belong to the item, so text a person typed with empty lines in it reads back the same. Rendering is deterministic, so an agent's edit of what it read matches it. Markdown outside the subset (HTML, tables, quotes, images, rules, setext or deeper headings, indented code, tilde fences, unbalanced emphasis or links, bad frontmatter or view JSON) throws `WmdSyntaxError` with its 1-based line; nothing is guessed at.

## Replica

`WmdReplica` is one Loro doc: built empty, or from a snapshot plus the updates logged after it. `markdown` projects the doc. `updates(since:)` exports what a version vector lacks (nil when nothing), and `importUpdate` imports one, reporting whether it changed the doc. An update whose causal dependencies the doc lacks throws `missingDependencies`; Loro holds its operations until the dependencies arrive.

`merge(markdown:base:peer:)` turns an agent's markdown into edits made at `base`, the frontiers of the version the agent read (nil: the doc as it is). It forks the doc at `base`, diffs the parsed markdown into the fork as `peer`, and returns the update, or nil when the markdown changes nothing. It leaves the replica as it was: the caller logs the update, then imports it. `peer` must be new to the document: a fork at an older `base` would reuse a known peer's counters.

The diff runs over what the agent read. Each block of the fork is keyed by the blocks its own markdown reads back as, so a block that renders to nothing (an empty paragraph) is never touched, and one whose text does not survive the round trip (a trailing newline) still counts as unchanged. Blocks the markdown keeps unchanged anchor a longest common subsequence. Inside each gap between anchors, a block is updated in place only when it pairs with a target block of its family (headings, paragraphs, list items, code, views) whose text is at least half similar (character-bigram Dice), choosing the order-preserving pairing of most similarity; every other block is deleted or inserted. So edits made since `base` survive in their own containers, and edits inside one paragraph interleave.
