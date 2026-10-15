# SessionToolsTestSupport

`ScriptOwnerContract` is an offline, reusable owner-facet contract: guarded files and frozen module snapshots, typed row edits/query observations, buffer-budget failures and replay-safe persistent tool receipts. Run it against any `ToolOwnerClient` and a fresh session. A contract violation throws `ScriptOwnerContractFailure`; domain failures remain typed.
