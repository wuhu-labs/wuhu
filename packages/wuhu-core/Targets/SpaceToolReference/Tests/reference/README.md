# Space tools

Each tool is one route, `POST /v1/tools/<name>`, taking the tool's input as its JSON body and answering its output. The CLI, the web app and the server's own agents all go through these tools.

| Tool | Input | Output |
| --- | --- | --- |
| [`read`](read.md) | [`ReadInput`](../../../SpaceContract/Tests/contract/read-input.schema.json) | [`ReadOutput`](../../../SpaceContract/Tests/contract/read-output.schema.json) |
| [`write`](write.md) | [`WriteInput`](../../../SpaceContract/Tests/contract/write-input.schema.json) | [`WriteOutput`](../../../SpaceContract/Tests/contract/write-output.schema.json) |
| [`edit`](edit.md) | [`EditInput`](../../../SpaceContract/Tests/contract/edit-input.schema.json) | [`EditOutput`](../../../SpaceContract/Tests/contract/edit-output.schema.json) |
| [`sync`](sync.md) | [`SyncInput`](../../../SpaceContract/Tests/contract/sync-input.schema.json) | [`SyncOutput`](../../../SpaceContract/Tests/contract/sync-output.schema.json) |
| [`rm`](rm.md) | [`RemoveInput`](../../../SpaceContract/Tests/contract/remove-input.schema.json) | [`RevisionOutput`](../../../SpaceContract/Tests/contract/revision-output.schema.json) |
| [`mv`](mv.md) | [`MoveInput`](../../../SpaceContract/Tests/contract/move-input.schema.json) | [`MoveOutput`](../../../SpaceContract/Tests/contract/move-output.schema.json) |
| [`ls`](ls.md) | [`ListInput`](../../../SpaceContract/Tests/contract/list-input.schema.json) | [`ListOutput`](../../../SpaceContract/Tests/contract/list-output.schema.json) |
| [`stat`](stat.md) | [`StatInput`](../../../SpaceContract/Tests/contract/stat-input.schema.json) | [`Entry`](../../../SpaceContract/Tests/contract/entry.schema.json) |
| [`grep`](grep.md) | [`GrepInput`](../../../SpaceContract/Tests/contract/grep-input.schema.json) | [`GrepOutput`](../../../SpaceContract/Tests/contract/grep-output.schema.json) |
| [`find`](find.md) | [`FindInput`](../../../SpaceContract/Tests/contract/find-input.schema.json) | [`FindOutput`](../../../SpaceContract/Tests/contract/find-output.schema.json) |
| [`history`](history.md) | [`HistoryInput`](../../../SpaceContract/Tests/contract/history-input.schema.json) | [`HistoryOutput`](../../../SpaceContract/Tests/contract/history-output.schema.json) |
| [`checkout`](checkout.md) | [`CheckoutInput`](../../../SpaceContract/Tests/contract/checkout-input.schema.json) | [`CheckoutOutput`](../../../SpaceContract/Tests/contract/checkout-output.schema.json) |
| [`query`](query.md) | [`QueryInput`](../../../SpaceContract/Tests/contract/query-input.schema.json) | [`QueryOutput`](../../../SpaceContract/Tests/contract/query-output.schema.json) |
| [`table.create`](table.create.md) | [`TableCreateInput`](../../../SpaceContract/Tests/contract/table-create-input.schema.json) | [`RevisionOutput`](../../../SpaceContract/Tests/contract/revision-output.schema.json) |
| [`table.alter`](table.alter.md) | [`TableAlterInput`](../../../SpaceContract/Tests/contract/table-alter-input.schema.json) | [`RevisionOutput`](../../../SpaceContract/Tests/contract/revision-output.schema.json) |
| [`table.mutate`](table.mutate.md) | [`TableMutateInput`](../../../SpaceContract/Tests/contract/table-mutate-input.schema.json) | [`TableMutateOutput`](../../../SpaceContract/Tests/contract/table-mutate-output.schema.json) |
| [`new`](new.md) | [`NewInput`](../../../SpaceContract/Tests/contract/new-input.schema.json) | [`NewOutput`](../../../SpaceContract/Tests/contract/new-output.schema.json) |
| [`attributes.read`](attributes.read.md) | [`AttributesReadInput`](../../../SpaceContract/Tests/contract/attributes-read-input.schema.json) | [`AttributesReadOutput`](../../../SpaceContract/Tests/contract/attributes-read-output.schema.json) |
| [`attributes.patch`](attributes.patch.md) | [`AttributesPatchInput`](../../../SpaceContract/Tests/contract/attributes-patch-input.schema.json) | [`AttributesPatchOutput`](../../../SpaceContract/Tests/contract/attributes-patch-output.schema.json) |

A refusal answers a [`ToolError`](../../../SpaceContract/Tests/contract/tool-error.schema.json) body: `400` when the body is not JSON or does not match the input schema, `422` when the tool refuses (its `code` says why, e.g. `notFound` or `conflict`). An unknown tool name is `404`.

Generated from the toolbox and the contract schemas by `bazel run //packages/wuhu-core:contract-export -- "$PWD"`. Edit those, not this page.
