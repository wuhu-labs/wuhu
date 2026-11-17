# Machines

A space's machines: their rows, names and groups; the box tunnel a machine dials and the operations it carries; execs
and file transfers; presence; the machine hub and the release job; the machine and exec routes and their gates.

The machine cell (`MachineCell`, keyed by the machine id) owns `machines`, `machine_v2_members`, `machine_presence`,
`machine_descriptions`, `machine_operations` and `machine_file_operations`. Its steps are its life: `create`, `enroll`,
`rotate`, `revoke`, `scope`, `move`, `reserve`, `start`, `stop`, `abandon`, `taken`, `detach`, `delete`, and the sockets
it serves (`BoxSocket`, `ExecStream`, `FileBulk`). The directory cell (`MachineDirectoryCell`, key `machines`) is its read
side over the shared database: the machine a name, a key or a pending token names, the machines a group may use, the v2
membership, the machine folders of a group's tree, and the exec records. It writes nothing.

A machine's credential is on its own row: at most one live key (`pubkey`, with `enrolled_at` and, for the app's one-call enrollment, the person in `enrolled_by`) and at most one pending join token (`token_hash`, the space's credential digest of the token, and `token_expires_at`); both are unique across machines. A machine is born with one of them: `addMachineV2` writes the token's hash, `enrollMachineV2(name:…pubkey:)` the key. The row is written before the name is claimed, and a refused claim deletes it, so a crash between them leaves a nameless machine its owner can delete, never a name nothing frees. `enrollMachineV2(token:pubkey:)` finds the machine by the token's hash and stores the key when the token is unexpired and the row has no key yet; the same token with the same key before expiry is the same answer again, and anything else is `JoinTokenRejected`. A key another machine holds is `alreadyExists`, from either path. `rotateMachine` clears the key and sets a new one-hour token, `revokeMachine` clears both, each closing the machine's box and file sockets in the same step; with `presenting`, revocation is the machine's own and is refused unless that is its key. Connection and the key-signed machine routes find the machine by its key. Delete removes the row with everything else. A machine has no account.

Access is one rule. A machine belongs to one group; `ReachScope.owner` admits that group alone and `reachable` every
group that may write in it, answered by the group cell's own role read. Machine routes act for a `MachineCaller` the
server maps its principal to; renaming, moving and the scope take an admin of the machine's group, its keys and deletion
a human admin, and every route that names a machine the caller may not use answers as if it did not exist.

The exec path: `reserveExec` creates an unopened operation the cell reaps after 60 seconds; the caller's leg
(`ExecSocketLink`) adapts the unchanged `MachineContract` frames to `ExecStream`; the box leg (`BoxLink`) speaks the v2
fetch tunnel. `MachineHub` prepares a start (secrets from the machine's group, the session's exec credential from the
server's identity), admits a caller to its own exec, and lists the attached machines. The session gate's script tokens
stay with the gate; the exec credential is `ExecCredentials`.

`Machines` is the family's entry point: the server builds it from the space's tenancy and group clients, the group's
notes, and a session summary read, then calls `register()` before the worker starts to give it the machine cells, the
directory, the read handles, and the buffers. `MachineDirectory` is the out-of-step client other families use;
`MachineMail` is what a cell posts to a machine cell; `MachineReading` and `MachinesReading` are the cell reads.
