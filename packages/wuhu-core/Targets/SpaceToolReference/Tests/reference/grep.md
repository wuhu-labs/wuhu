# `grep`

Search file contents under `path` (default `/`), or in that one file, line by line for an ICU regular expression. Hidden entries (dot-names, `/_` and `/users` at a space root) and what `.gitignore` files exclude are passed over unless `hidden` or `noIgnore` asks for them, as are binary files and files with a line over 64 KiB; `skipped` counts each reason with one example. A page stops at `matchLimit` (default 50, at most 1000) or its scan budget, never on time; a non-null `cursor` in the answer is the `step` that continues the search. A search still running after 30 s fails `unavailable`.

`POST /v1/tools/grep` takes a [`GrepInput`](../../../SpaceContract/Tests/contract/grep-input.schema.json) body and answers `200` with a [`GrepOutput`](../../../SpaceContract/Tests/contract/grep-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `pattern` | string | yes |
| `path` | string or null | no |
| `matchLimit` | integer or null | no |
| `hidden` | boolean or null | no |
| `noIgnore` | boolean or null | no |
| `step` | string or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `matches` | array of object | yes |
| `matches[].path` | string | yes |
| `matches[].line` | integer | yes |
| `matches[].text` | string | yes |
| `cursor` | string or null | no |
| `scanned` | integer | yes |
| `skipped` | array of object | yes |
| `skipped[].reason` | one of `"hidden"`, `"ignored"`, `"binary"`, `"longLine"`, `"unreadable"` | yes |
| `skipped[].count` | integer | yes |
| `skipped[].example` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
