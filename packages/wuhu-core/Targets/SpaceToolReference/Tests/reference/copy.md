# `copy`

Copy one file onto or off a machine: machine to machine, machine to space or space to machine, never space to space. The server streams the bytes; a machine target lands whole or not at all, after its sha256 is checked. An existing `to` fails with `exists` unless `overwrite` is true; a source that changes mid-copy fails with `sourceChanged`; a folder at `from` is refused. A space target takes at most 64 MiB.

`POST /v1/tools/copy` takes a [`CopyInput`](../../../SpaceContract/Tests/contract/copy-input.schema.json) body and answers `200` with a [`CopyOutput`](../../../SpaceContract/Tests/contract/copy-output.schema.json).

## Input

| Field | Type | Required |
| --- | --- | --- |
| `from` | string | yes |
| `to` | string | yes |
| `overwrite` | boolean or null | no |

## Output

| Field | Type | Required |
| --- | --- | --- |
| `bytes` | integer | yes |
| `sha256` | string | yes |
| `token` | string | yes |

## Errors

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
