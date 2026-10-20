# `table.rows`

The named-column form of table.mutate: ops are `{insert: {col: v}}`, `{update: id, set: {col: v}}` or `{delete: id}`, applied in one revision; `ids` are the inserted rows' ids.

`POST /v1/tools/table.rows` takes a [`TableRowsInput`](../../../SpaceContract/Tests/contract/table-rows-input.schema.json) body and answers `200` with a [`TableMutateOutput`](../../../SpaceContract/Tests/contract/table-mutate-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `ops` | any JSON | yes |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `rev` | integer | yes |
| `ids` | array of integer | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
