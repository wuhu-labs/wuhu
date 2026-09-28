# Wire schemas

Every JSON body on the `/v1` surface is a Swift contract type. Each type's JSON Schema (draft 2020-12) is generated from the Swift source and checked in:

- [`SpaceContract/Tests/contract/`](../packages/wuhu-core/Targets/SpaceContract/Tests/contract/): the space API, which covers tools, sessions, conversations, accounts, enrollment and observation.
- [`MachineContract/Tests/contract/`](../packages/wuhu-core/Targets/MachineContract/Tests/contract/): the machine domain, which covers the frame protocol between the server and a machine agent, exec events and machine admin.

A file is named after its type in kebab case (`SessionCreateInput` is `session-create-input.schema.json`), and its `title` is the type name. The [HTTP API](http-api.md) and the [space tool pages](../packages/wuhu-core/Targets/SpaceToolReference/Tests/reference/README.md) name the type each route takes and answers.

What a schema cannot carry, such as ordering, idempotency and who may call what, is in the SPEC.md next to each target:

- [SpaceContract](../packages/wuhu-core/Targets/SpaceContract/SPEC.md): the space's wire semantics.
- [SpaceServer](../packages/wuhu-core/Targets/SpaceServer/SPEC.md): routes, auth and groups.
- [MachineContract](../packages/wuhu-core/Targets/MachineContract/SPEC.md), [MachineChannel](../packages/wuhu-core/Targets/MachineChannel/SPEC.md) and [MachineAgent](../packages/wuhu-core/Targets/MachineAgent/SPEC.md): the machine protocol.

`bazel run //packages/wuhu-core:contract-export -- "$PWD"` regenerates the schemas and the tool pages; the golden tests fail until the checked-in files match the Swift types.

The API is pre-1.0 and may change with any release.
