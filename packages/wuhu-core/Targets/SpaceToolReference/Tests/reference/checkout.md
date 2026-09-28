# `checkout`

Restore a path's content from revision `rev` as a new revision. History never rewinds.

`POST /v1/tools/checkout` takes a [`CheckoutInput`](../../../SpaceContract/Tests/contract/checkout-input.schema.json) body and answers `200` with a [`CheckoutOutput`](../../../SpaceContract/Tests/contract/checkout-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `rev` | integer | yes |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `rev` | integer | yes |
| `token` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
