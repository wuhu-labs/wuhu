# `table.schema`

Read a table's ordered header and token, at the head or at rev.

`POST /v1/tools/table.schema` takes a [`TableSchemaInput`](../../../SpaceContract/Tests/contract/table-schema-input.schema.json) body and answers `200` with a [`TableSchemaOutput`](../../../SpaceContract/Tests/contract/table-schema-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `rev` | integer or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `header` | object | yes |
| `header.columns` | array of object | yes |
| `header.columns[].name` | string | yes |
| `header.columns[].type` | one of `"string"`, `"integer"`, `"number"`, `"boolean"`, `"json"` | yes |
| `token` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
