---
name: data-organization
description: Propose how a person's loose notes should live in Wuhu — a table, docs with YAML frontmatter, or both — with a surface on top, before changing anything.
---

# Organizing data in a space

Two primitives carry structure, and most real collections want both.

## A table

A `.table` file is a SQLite table: typed columns, rows updated by `mutateRows`, queried and observed by pages, views and widgets. It fits things that share one shape, are sorted and filtered by status or date, and change often — applications, expenses, contacts, tasks. A good first schema has at most eight columns, named for what the person asks about ("where does it stand" → `stage`; "what's due" → `due`; "don't lose contacts" → `contact`), with dates as ISO text (`2026-10-16`) so they sort.

## Docs with frontmatter

A markdown file with a YAML header carries a few structured fields and as much prose as the item needs — interview impressions, a recipe, a meeting. The `docs` and `doc_custom_attrs` tables expose the frontmatter to SQL, so a board or widget can select from them too. It fits items that are mostly text, read one at a time, and edited by hand.

## Both

The common shape: a table as the source of truth for state and dates, one doc per item for the story, and a `notes` column holding the doc's path. The person edits whichever side the change belongs to.

## Something to look at

A structure nobody looks at rots. On top of the table, one of: a `.view` kanban grouped by the status column (read-only, lives in the app), a widget at `/.widgets/<name>.json` for the one number or list that matters on the Home/Lock Screen, or an HTML page when they need to edit rows from the phone. Updates happen by telling a session ("Corvid moved me to onsite") or through the page.

## The proposal

The person approves a proposal they can read in a minute: the shape you recommend and why, the columns, the surface on top, what happens to the existing files (they stay until the migration is checked), and the one or two questions you need answered. Grounded in their actual items, not generic. Nothing is created until they say go.
