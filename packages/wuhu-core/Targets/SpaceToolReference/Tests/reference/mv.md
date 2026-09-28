# `mv`

Move a path. An existing `to` refuses the move unless `replace` is true. `dangling` lists the documents whose links still point at the old path.

`POST /v1/tools/mv` takes a [`MoveInput`](../../../SpaceContract/Tests/contract/move-input.schema.json) body and answers `200` with a [`MoveOutput`](../../../SpaceContract/Tests/contract/move-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `from` | string | yes |
| `to` | string | yes |
| `replace` | boolean or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `rev` | integer or null | no |
| `dangling` | array of string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
