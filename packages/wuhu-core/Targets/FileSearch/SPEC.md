# FileSearch

One find or grep engine over any walkable backend. A backend is a `SearchSource`: `kind(path)`, `children(of:from:limit:)` (a page of a directory's children in UTF-8 byte order of their names, from a name on, with the name the next page starts at), `open(file)` to a `SearchReader` read a range at a time, and `isHidden(path)`. The engine owns everything else: the walk, `.gitignore`, matching, paging, skips and budgets, so a space, the system files and a machine's disk page the same tree the same way.

`SearchQuery{mode, pattern, root, scope, hidden, noIgnore, limit, step}.run(in:clock:)` answers one `SearchPage{hits, cursor?, scanned, skipped}`. The walk is depth-first, siblings in byte order. find matches a glob against paths relative to `root` and lists leaves (files and `other`), grep matches an ICU regex against each line of each file. `validate()` refuses a bad pattern, glob, limit or step with a typed `SearchError` before any walk; a missing root is `notFound`.

A page ends on counts and bytes only, never on time (`SearchLimits`): `limit` hits (default 50, capped at 1000), 48 KiB of hits, 10,000 entries visited, 16 MiB read. Every unit of work counts: a directory is listed in batches no larger than the entries left, and searched files (binary ones included) and `.gitignore` files count their bytes read. A file larger than what is left is continued mid-file on the next page, so any file is searched to its end. A `.gitignore` of 64 KiB or more is skipped as unreadable. The `.gitignore` files above the root are read again by every page, so they may take at most 8 MiB of its budget, each reserved at 64 KiB; one past that is skipped as unreadable, the same way on every page. A search still running after 30 s on `clock` fails `timeout`, cancelling the walk; there is no partial page.

`cursor` is present iff the page stopped before the walk ended. It is bound to the query (mode, pattern, root, scope, hidden, noIgnore; not the limit): `scope` is the caller's name for the backend `root` is a path in, so a cursor from one space group, machine or the system files is `invalidStep` on another.

`skipped` has one `{reason, count, example}` per reason entries were passed over: hidden (the source's `isHidden`), ignored, binary (a NUL in the first read), longLine (a line over 64 KiB) and unreadable (`SearchUnreadable` from the source). Any other error a source throws ends the search.

Tests are black-box over an in-memory source: walk order, globs, ignore rules, every budget and skip, cursor binding and the deadline.
