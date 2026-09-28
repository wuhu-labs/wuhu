# `table.create`

Create a table at a `.table` path with the given columns.

`POST /v1/tools/table.create` takes a [`TableCreateInput`](../../../SpaceContract/Tests/contract/table-create-input.schema.json) body and answers `200` with a [`RevisionOutput`](../../../SpaceContract/Tests/contract/revision-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `header` | object | yes |
| `header.columns` | array of object | yes |
| `header.columns[].name` | string | yes |
| `header.columns[].type` | one of `"string"`, `"integer"`, `"number"`, `"boolean"`, `"json"` | yes |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `rev` | integer | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
