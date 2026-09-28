# `table.mutate`

Insert, update and delete rows in one revision. `values` follow the header's column order; `ids` are the inserted rows' ids.

`POST /v1/tools/table.mutate` takes a [`TableMutateInput`](../../../SpaceContract/Tests/contract/table-mutate-input.schema.json) body and answers `200` with a [`TableMutateOutput`](../../../SpaceContract/Tests/contract/table-mutate-output.schema.json).

## Input

| Field | Type | Required | When |
| --- | --- | --- | --- |
| `path` | string | yes | always |
| `ops` | array of object | yes | always |
| `ops[].kind` | one of `"insert"`, `"update"`, `"delete"` | yes | always |
| `ops[].values` | array of any JSON | yes | `kind` is `"insert"` |
| `ops[].row` | integer | yes | `kind` is `"update"` |
| `ops[].values` | array of any JSON | yes | `kind` is `"update"` |
| `ops[].row` | integer | yes | `kind` is `"delete"` |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `rev` | integer | yes |
| `ids` | array of integer | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
