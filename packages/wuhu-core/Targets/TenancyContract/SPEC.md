# Tenancy contract

The space's identity vocabulary other families name and read: machine names, accounts' keys, devices, join tokens, and
the space cell's reads over them.

`KeyCapability` and `KeyRecord` describe an account key; `DeviceKind` and `DeviceRecord` a device; `JoinToken`,
`MintedJoinToken` and `JoinTokenRejected` the space's one-time enrollment token, whose shape a machine's join token
shares.

`SpaceReading` is one cell's reads: the space cell answers a machine's current name, every machine's name, the machine a
spelling names, and the groups a group may write. `CellContext.space()` resolves the provided `TenancyCells` factory; an
unprovided factory traps. `TenancyClient` is the out-of-step half the machine family calls, and all it asks of the
space: device links (the links, the accounts linked to a machine, a device, annotating and detaching), groups (the
list, a spelling, a reach) and names (`claimMachine` reserves a new machine's name, `renameMachine`, `freeMachine`),
each a call on its owner. SpaceCore provides both.
