# `attributes.read`

Read a Markdown file's frontmatter as an object, with the version token `attributes.patch` takes.

`POST /v1/tools/attributes.read` takes a [`AttributesReadInput`](../../../SpaceContract/Tests/contract/attributes-read-input.schema.json) body and answers `200` with a [`AttributesReadOutput`](../../../SpaceContract/Tests/contract/attributes-read-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `attributes` | any JSON | yes |
| `token` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
