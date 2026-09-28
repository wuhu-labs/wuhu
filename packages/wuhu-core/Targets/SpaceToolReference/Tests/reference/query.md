# `query`

Run a read-only `SELECT` over the space's tables and induced tables.

`POST /v1/tools/query` takes a [`QueryInput`](../../../SpaceContract/Tests/contract/query-input.schema.json) body and answers `200` with a [`QueryOutput`](../../../SpaceContract/Tests/contract/query-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `sql` | string | yes |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `columns` | array of string | yes |
| `rows` | array of array of any JSON | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
