# `ls`

List a folder's entries, at the head or at `rev`. At `/` the system folder `/_` and `/users` are left out unless `hidden` is true.

`POST /v1/tools/ls` takes a [`ListInput`](../../../SpaceContract/Tests/contract/list-input.schema.json) body and answers `200` with a [`ListOutput`](../../../SpaceContract/Tests/contract/list-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `rev` | integer or null | no |
| `hidden` | boolean or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `rev` | integer or null | no |
| `entries` | array of object | yes |
| `entries[].name` | string | yes |
| `entries[].kind` | one of `"file"`, `"directory"`, `"table"`, `"symlink"` | yes |
| `entries[].size` | integer | yes |
| `entries[].lineCount` | integer or null | no |
| `entries[].token` | string | yes |
| `entries[].mtime` | number | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
