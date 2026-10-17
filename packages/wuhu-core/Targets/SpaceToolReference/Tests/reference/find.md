# `find`

Find files under `path` (default `/`) whose path relative to `path` matches a glob in the `.gitignore` dialect, passing over and paging like `grep`.

`POST /v1/tools/find` takes a [`FindInput`](../../../SpaceContract/Tests/contract/find-input.schema.json) body and answers `200` with a [`FindOutput`](../../../SpaceContract/Tests/contract/find-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `glob` | string | yes |
| `path` | string or null | no |
| `matchLimit` | integer or null | no |
| `hidden` | boolean or null | no |
| `noIgnore` | boolean or null | no |
| `step` | string or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `paths` | array of string | yes |
| `cursor` | string or null | no |
| `scanned` | integer | yes |
| `skipped` | array of object | yes |
| `skipped[].reason` | one of `"hidden"`, `"ignored"`, `"binary"`, `"longLine"`, `"unreadable"` | yes |
| `skipped[].count` | integer | yes |
| `skipped[].example` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
