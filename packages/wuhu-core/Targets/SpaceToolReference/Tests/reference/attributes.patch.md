# `attributes.patch`

Set and remove top-level frontmatter keys of a Markdown file, keeping the rest of its YAML. A stale `ifMatch` is `conflict`, carrying the current `token`.

`POST /v1/tools/attributes.patch` takes a [`AttributesPatchInput`](../../../SpaceContract/Tests/contract/attributes-patch-input.schema.json) body and answers `200` with a [`AttributesPatchOutput`](../../../SpaceContract/Tests/contract/attributes-patch-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `set` | any JSON | no |
| `remove` | array of string or null | no |
| `ifMatch` | string | yes |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `token` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
