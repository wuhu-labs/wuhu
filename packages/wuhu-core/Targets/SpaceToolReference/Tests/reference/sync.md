# `sync`

Save a full-text draft of a file read at `baseToken`. The answer's `kind` says whether the draft was `saved` as is, `merged` with the changes made since, or hit a `conflict`, in which case nothing is written.

`POST /v1/tools/sync` takes a [`SyncInput`](../../../SpaceContract/Tests/contract/sync-input.schema.json) body and answers `200` with a [`SyncOutput`](../../../SpaceContract/Tests/contract/sync-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `baseToken` | string | yes |
| `content` | string | yes |

## Output

| Field | Type | Required | When |
| --- | --- | --- | --- |
| `kind` | one of `"saved"`, `"merged"`, `"conflict"` | yes | always |
| `rev` | integer | yes | `kind` is `"saved"` |
| `token` | string | yes | `kind` is `"saved"` |
| `content` | string | yes | `kind` is `"saved"` |
| `rev` | integer | yes | `kind` is `"merged"` |
| `token` | string | yes | `kind` is `"merged"` |
| `content` | string | yes | `kind` is `"merged"` |
| `token` | string | yes | `kind` is `"conflict"` |
| `content` | string | yes | `kind` is `"conflict"` |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
