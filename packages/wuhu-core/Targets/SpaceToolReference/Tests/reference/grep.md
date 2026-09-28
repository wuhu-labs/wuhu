# `grep`

Search file contents under `path` (default `/`) for a regular expression. A non-null `cursor` in the answer is the `step` that continues the search.

`POST /v1/tools/grep` takes a [`GrepInput`](../../../SpaceContract/Tests/contract/grep-input.schema.json) body and answers `200` with a [`GrepOutput`](../../../SpaceContract/Tests/contract/grep-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `pattern` | string | yes |
| `path` | string or null | no |
| `matchLimit` | integer or null | no |
| `entryLimit` | integer or null | no |
| `step` | string or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `matches` | array of object | yes |
| `matches[].path` | string | yes |
| `matches[].line` | integer | yes |
| `matches[].text` | string | yes |
| `matches[].context` | array of string | yes |
| `cursor` | string or null | no |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
