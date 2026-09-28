# `find`

Find paths under `path` (default `/`) matching a glob, paged like `grep`.

`POST /v1/tools/find` takes a [`FindInput`](../../../SpaceContract/Tests/contract/find-input.schema.json) body and answers `200` with a [`FindOutput`](../../../SpaceContract/Tests/contract/find-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `glob` | string | yes |
| `path` | string or null | no |
| `matchLimit` | integer or null | no |
| `entryLimit` | integer or null | no |
| `step` | string or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `paths` | array of string | yes |
| `cursor` | string or null | no |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
