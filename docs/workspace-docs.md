# Workspace docs (knowledge base)

Wuhu’s “workspace docs” are a convention-based, filesystem knowledge base rooted at the server’s data root:

- `<data-root>/workspace/`

Every `.md` file under that directory is treated as a document.

## Frontmatter

Docs may begin with YAML frontmatter (`---` … `---`). Frontmatter is treated as structured attributes (for example `type`, `status`, `assignee`, `priority`, `tags`), but any key/value pairs are allowed.

## Issues

Docs under:

- `<data-root>/workspace/issues/`

are treated as issues. Frontmatter should include at minimum:

- `status`: `open`, `in-progress`, `done` (or your own statuses)

## Server API

- `GET /v1/workspace/docs` — list docs (path + frontmatter attributes)
- `GET /v1/workspace/doc?path=…` — read a doc (frontmatter + markdown body)

## App UI (MVP)

- Workspace docs are read-only in the app (editing happens via agents or direct file edits).
- Frontmatter fields are rendered as tags/badges.
- Issues render in a kanban-style view grouped by `status`.

