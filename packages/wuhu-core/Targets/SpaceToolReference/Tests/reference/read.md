# `read`

Read a file's UTF-8 text, at the head or at a past revision `rev`. `lines` (`A-B`, 1-based, inclusive) cuts a range. A file that is not UTF-8 text is `unsupported`, unless `image` is set and the path is an image: then its checked bytes go to the blob store and `image` names them.

`POST /v1/tools/read` takes a [`ReadInput`](../../../SpaceContract/Tests/contract/read-input.schema.json) body and answers `200` with a [`ReadOutput`](../../../SpaceContract/Tests/contract/read-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `path` | string | yes |
| `rev` | integer or null | no |
| `lines` | string or null | no |
| `image` | boolean or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `token` | string | yes |
| `content` | string | yes |
| `image` | object or null | no |
| `image.mimeType` | string | yes |
| `image.blob` | string | yes |
| `image.byteCount` | integer | yes |
| `image.width` | integer or null | no |
| `image.height` | integer or null | no |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
