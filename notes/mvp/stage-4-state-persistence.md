# Stage 4: State Persistence

Split into sub-stages for cleaner implementation.

## Stage 4.1: Database Schema + Core State API

See [stage-4.1-db-state-api.md](./stage-4.1-db-state-api.md)

Add Postgres tables for session/message storage:
- Schema for sessions and messages tables
- Core endpoints to receive and query state
- Unit tests for persistence functions

Deliverables: Schema + migration, state API, unit tests.

## Stage 4.2: Daemon State Persistence

See [stage-4.2-daemon-persistence.md](./stage-4.2-daemon-persistence.md)

Daemon calls Core API after each turn:
- Turn completion hook
- Message conversion (Pi events → UI format)
- Cursor tracking

Deliverables: Daemon persistence logic, integration test.

## Stage 4.3: S3/Minio Raw Log Archive

See [stage-4.3-s3-raw-logs.md](./stage-4.3-s3-raw-logs.md)

Upload raw Pi session logs to Minio:
- Full event logs for debugging/replay
- Upload after each turn completes
- Presigned URLs for retrieval

Deliverables: Minio client, log endpoints, unit tests.

## Stage 4.4: Web UI History + SSE Resume

See [stage-4.4-web-history.md](./stage-4.4-web-history.md)

Load history and resume streaming seamlessly:
- Loader fetches messages from DB
- SSE starts from cursor, no gaps
- Handles reconnection gracefully

Deliverables: Web loader + SSE integration, e2e test.

## Key Concepts

### Turn Definition

A turn means: human message → AI tool call loop → AI final summary (no more tools)

### Split State

1. **UI State (Postgres)** - converted messages for display, with cursor
2. **Raw Logs (Minio)** - full Pi agent logs, immutable archive

### Future Concern (Deferred)

Cloud sandboxes won't have direct access to internal API. Options for later:
- Public ingress endpoint
- Message queue
- WebSocket tunnel

MVP uses in-cluster direct calls.
