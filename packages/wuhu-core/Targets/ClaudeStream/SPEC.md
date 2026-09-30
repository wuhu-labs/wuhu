# ClaudeStream

The stream reader decodes Claude Code JSONL frames, including `assistant` frames with message id, model, timestamp and per-message usage. Missing or mistyped required assistant fields are malformed frames, not silently ignored data.

`ClaudeInferenceCalls.record` consumes stream frames and returns completed calls. Consecutive assistant frames for one `message.id` retain the first timestamp and the last model and usage. A different assistant id, a user/tool-result frame, or a turn result completes the pending call; process EOF drains the last call. Completed ids are not emitted again. The host persists each completed call before forwarding the boundary frame, so a server stop mid-turn does not lose earlier completed calls. Result-frame usage is turn-level context information, never an inference row.
