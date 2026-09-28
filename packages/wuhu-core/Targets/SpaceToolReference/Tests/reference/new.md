# `new`

Instantiate a template document, next to it or in the folder `in`, and answer the new path.

`POST /v1/tools/new` takes a [`NewInput`](../../../SpaceContract/Tests/contract/new-input.schema.json) body and answers `200` with a [`NewOutput`](../../../SpaceContract/Tests/contract/new-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `template` | string | yes |
| `in` | string or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
