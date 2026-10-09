# `history`

A page of a path's revisions, oldest first: what each changed and, where recorded, who made it. Pass next as after to continue (default limit 100, maximum 500).

`POST /v1/tools/history` takes a [`HistoryInput`](../../../SpaceContract/Tests/contract/history-input.schema.json) body and answers `200` with a [`HistoryOutput`](../../../SpaceContract/Tests/contract/history-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `after` | integer or null | no |
| `limit` | integer or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `entries` | array of object | yes |
| `entries[].rev` | integer | yes |
| `entries[].mtime` | number | yes |
| `entries[].change` | one of `"write"`, `"delete"`, `"move"`, `"checkout"` | yes |
| `entries[].to` | string or null | no |
| `entries[].fromRev` | integer or null | no |
| `entries[].by` | string or null | no |
| `entries[].via` | string or null | no |
| `next` | integer or null | no |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
