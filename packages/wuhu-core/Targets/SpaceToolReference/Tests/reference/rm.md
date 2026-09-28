# `rm`

Remove a path. With `ifMatch`, only if it is still at that version token.

`POST /v1/tools/rm` takes a [`RemoveInput`](../../../SpaceContract/Tests/contract/remove-input.schema.json) body and answers `200` with a [`RevisionOutput`](../../../SpaceContract/Tests/contract/revision-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `ifMatch` | string or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `rev` | integer | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
