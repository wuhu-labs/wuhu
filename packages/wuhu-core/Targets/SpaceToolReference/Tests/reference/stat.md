# `stat`

One path's metadata: kind, size, line count, version token and modification time.

`POST /v1/tools/stat` takes a [`StatInput`](../../../SpaceContract/Tests/contract/stat-input.schema.json) body and answers `200` with a [`Entry`](../../../SpaceContract/Tests/contract/entry.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `name` | string | yes |
| `kind` | one of `"file"`, `"directory"`, `"table"`, `"symlink"` | yes |
| `size` | integer | yes |
| `lineCount` | integer or null | no |
| `token` | string | yes |
| `mtime` | number | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
