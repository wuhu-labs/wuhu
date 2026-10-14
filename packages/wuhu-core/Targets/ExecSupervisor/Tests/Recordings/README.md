# Live exec recordings

These fixtures record bounded private-Unix HTTP exchanges and observed process effects. Nonces, credentials and cookies are excluded. Build provenance names the full source SHA; the baseline old supervisor is distinct from the new agent.

The coordinator-cursor-handoff fixture models persisted output cursor reuse only; actual Wuhu server process restart is deferred to slice 5.

Replay is a production OperationClient/MemoryOperationStore consumer, not a frame echo. It emits fresh requests, checks them against the recording (normalizing JSON order, defaults and diagnostics only), commits output/cursors and real verdicts, and recreates a coordinator on the same store for cursor handoff. Process effects remain observed evidence from the live driver; CI separately runs production pipes, spawn failures, FD inheritance, stop races, reaping and a TERM-ignore/SIGKILL grace test. Temporarily deleting SIGKILL escalation made the named grace test fail with timeout.

The recovery-isolation fixture starts three authenticated responders then SIGSTOPs them, leaves an empty/torn operation directory, and restarts the agent while a healthy exec drains byte-exact output. Restart must bind in under five seconds without awaiting those identities.
