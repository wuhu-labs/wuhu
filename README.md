# wuhu (Swift)

Swift 6.2 pivot of Wuhu.

## CLI

```bash
swift run wuhu --help

# Create a persisted session (prints session id)
swift run wuhu create-session --provider openai

# Send a prompt to an existing session (streams assistant output)
swift run wuhu prompt --session-id <session-id> "What's the weather in Tokyo?"

# Retrieve full transcript
swift run wuhu get-session --session-id <session-id>

# List sessions
swift run wuhu list-sessions
```

The CLI reads `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` from the environment and will also load a local `.env` if present.
