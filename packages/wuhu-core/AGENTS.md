# wuhu-core

New features ship with parity between the CLI and scripts (`run_script`), wherever the operation makes sense on both sides.

## Database schema

- `space.sqlite` is opened by `Space.open` in `Targets/SpaceCore/Sources/Space.swift`. `MigrationRunner` runs the frozen baseline (`Migrations.baseline`, identifiers 001–056) and then each family's chain, in `MigrationFamily` order, on the writer's own connection, before the space is usable. Applied identifiers live in `grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)` in the same database — the ledger GRDB wrote, kept in its name and shape so an existing database opens as it is; each migration runs once, in registration order, in its own `BEGIN IMMEDIATE` transaction, and a chain migration is recorded by its family and position (`group/0001`, `group/0002`, …). In-memory spaces use the same migration path.
- A new migration goes at the end of its family's chain: append it to that `MigrationChain` in `Migrations.chains` (`Migrations.swift`) and keep its body with the family it serves. Its identifier is its position in the chain, so a chain is append-only: never reorder it or insert where a database may already have run the next one. Never add to the baseline and never edit an applied migration: a database that already ran it keeps the old schema, and a database whose ledger names an identifier the code no longer registers refuses to open. Migration 001 establishes the baseline on both a fresh database and an existing database at the baseline schema.
- A migration may read, reshape, and write any rows, but must be self-contained: raw SQL and local code only, never types defined elsewhere. Freeze the meaning of a migration when it is written so later application refactors cannot change an upgrade.
- Rehearse data-changing upgrades against a copy of the existing database, back it up before rollout, and fix forward. Never delete a space database to upgrade it: its revision journal and real content live there.
- Test upgrades and fresh creation through the real SQLite-backed space, asserting the resulting schema and preserved behavior rather than source text or implementation details.
- Outside migrations, StructuredQueries is the query idiom. When new work interacts heavily with an existing raw-SQL store, migrate that store to StructuredQueries in the same change and keep its black-box behavior tests.
