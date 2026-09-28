# `edit`

Apply exact text replacements in order. Each `old` must occur exactly once in the text as the earlier edits left it; otherwise nothing is written.

`POST /v1/tools/edit` takes a [`EditInput`](../../../SpaceContract/Tests/contract/edit-input.schema.json) body and answers `200` with a [`EditOutput`](../../../SpaceContract/Tests/contract/edit-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `edits` | array of object | yes |
| `edits[].old` | string | yes |
| `edits[].new` | string | yes |
| `ifMatch` | string or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `rev` | integer or null | no |
| `token` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
