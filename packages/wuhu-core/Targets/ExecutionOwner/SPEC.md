# ExecutionOwner

`AttemptLogConfig` composes an injected, parent-owned trace sink. Opening preserves truncation on each HTTP fetch and once per WebSocket attempt, append remains awaited best-effort, and each chunk is written before forwarding so partial trace evidence survives cancellation. No filesystem path enters inference execution. The execution boundary and media resolver live in SessionTools; this target owns only trace-file configuration.
