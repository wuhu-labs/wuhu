# Machines contract

What other families name of a machine and ask of the machine family, and the values a machine read hands back.

`MachineRecord` is a machine's row and its current name; `ExecRecord` an exec as its owner records it, with
`ExecTerminalState` its end. `MachineName` validates a machine's name; `MachineV2Presence`/`MachineV2PresenceEvidence`
are a machine's public presence and when it was seen. `MachineExec`, `MachineExecReply` and `ExecFinished` are the exec job's request and answer.

`MachineReading` is one machine cell's reads and `MachineCells`/`CellContext.machine(_:)` resolve them; `MachinesReading`
is the directory cell's reads (`MachinesCells`/`CellContext.machines()`). `MachineDirectory` is the out-of-step client:
the reads and calls another family makes of machines, implemented by the machine family and wired by the server.
`MachineMail` is what a cell posts to a machine cell (an exec's start, detach and hand-back), and `MachineCaller` is who a machine route acts for; the server
maps its principal to it. This target does not depend on `TenancyContract`: a machine's key and join token are the
machine family's own, and nothing here names an account key.
