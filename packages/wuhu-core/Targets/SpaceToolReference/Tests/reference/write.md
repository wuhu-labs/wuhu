# `write`

Create or replace a file with UTF-8 text. With `ifMatch`, the write succeeds only if the file is still at that version token.

`POST /v1/tools/write` takes a [`WriteInput`](../../../SpaceContract/Tests/contract/write-input.schema.json) body and answers `200` with a [`WriteOutput`](../../../SpaceContract/Tests/contract/write-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `content` | string | yes |
| `ifMatch` | string or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `rev` | integer or null | no |
| `token` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
