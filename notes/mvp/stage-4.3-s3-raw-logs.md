# Stage 4.3: S3/Minio Raw Log Archive

Upload raw Pi session logs to Minio after each turn.

## Prerequisites

- Stage 4.2 complete (daemon persistence flow exists)

## Purpose

Raw logs are the complete Pi agent session - useful for:
- Debugging issues
- Replaying sessions
- Audit trail

UI messages (Stage 4.1/4.2) are a lossy conversion for display. Raw logs are the source of truth.

## Minio Setup

Already have Minio in cluster. Need:
- Bucket: `wuhu-raw-logs`
- Access via S3-compatible API

## Log Format

Path pattern: `sessions/{session_id}/turn-{turn_index}.jsonl`

Each line is a raw Pi agent event (JSON).

## Core API

### POST /sandboxes/:id/logs

Upload raw log for a turn.

Request (multipart or raw body):
```
Content-Type: application/x-ndjson

{"type":"turn_start","timestamp":1234567890}
{"type":"message_start","content":""}
...
```

Query params:
- `turnIndex`: Which turn this log is for

Core:
1. Streams body directly to Minio
2. Returns presigned URL for retrieval (optional)

### GET /sandboxes/:id/logs/:turnIndex

Get presigned URL to download raw log.

Response:
```json
{
  "url": "https://minio.../sessions/abc/turn-1.jsonl?...",
  "expiresIn": 3600
}
```

## Daemon Changes

After state POST succeeds, daemon:
1. Collects raw events from the turn
2. POSTs to Core `/sandboxes/:id/logs?turnIndex=N`

## Validates

Unit tests:
- Upload to Minio works
- Presigned URL generation works
- Download retrieves correct content

Integration test:
- Daemon completes turn
- Raw log appears in Minio
- Can download via presigned URL

## Deliverables

1. Minio client in Core
2. Log upload/download endpoints
3. Daemon log upload after turn
4. Unit + integration tests
