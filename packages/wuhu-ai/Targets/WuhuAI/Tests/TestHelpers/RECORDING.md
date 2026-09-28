# JiuziAI Recording System

## Overview

Integration tests in JiuziAI use a **record-replay** system. Real HTTP responses are
captured once and replayed thereafter — no API keys needed for normal test runs.

Recordings live under `Tests/IntegrationTests/Recordings/<name>/`, with
`<n>.request.json` (sanitized request body) and `<n>.output.sse` (SSE response).

## Modes

| Env | Mode | Behavior |
|---|---|---|
| unset | `replay` | Compare request body against recording; replay SSE. |
| `RECORDING=1` | `recordAll` | Make real API calls; overwrite **all** recordings run. |
| `RECORDING=<prefix>` | `recordOnly` | Only record tests whose name starts with `<prefix>`; replay others. |

## When recordings break

Recordings compare the **sanitized request body** (headers HMAC'd, nothing
provider-specific leaked). If you change request-building logic (new fields,
different defaults, different wire format), the recorded body no longer matches
and tests fail with `requestBodyMismatch`.

### How to update recordings

1. **Identify the exact scope.** Don't re-record everything — figure out which
   test suites and which recording directories are affected.

2. **Delete only the affected directories**, then re-record with a filtered
   `RECORDING=1` run:

   ```bash
   # Delete affected recording dirs
   rm -rf Tests/IntegrationTests/Recordings/<name1> \
          Tests/IntegrationTests/Recordings/<name2>

   # Re-record only the affected test suite
   RECORDING=1 swift test --package-path Packages/Jiuzi \
       --filter "<TestSuiteName>"
   ```

3. **Verify the full suite passes** without RECORDING afterwards.

### Avoid re-recording when possible

- If only **some test cases** in a suite are affected, use `RECORDING=<prefix>`
  instead of `RECORDING=1` to avoid touching unaffected recordings.
- If the test's **purpose** doesn't depend on the default behavior that changed,
  consider pinning the old value explicitly (e.g., `reasoning: .none`) instead
  of re-recording.

### Common pitfalls

- `RECORDING=1` with `--filter <SuiteName>` will re-record **all** test cases
  in that suite, not just the affected ones. This is harmless (recordings that
  haven't changed will be rewritten identically) but wasteful.
- API keys must be available in the environment. The test harness reads:
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`,
  `GEMINI_API_KEY`, `MOONSHOT_API_KEY`.

## API key sourcing

Export the keys before recording. If they live in fish universal variables:

```bash
export OPENAI_API_KEY=$(fish -c 'echo $OPENAI_API_KEY')
export ANTHROPIC_API_KEY=$(fish -c 'echo $ANTHROPIC_API_KEY')
export DEEPSEEK_API_KEY=$(fish -c 'echo $DEEPSEEK_API_KEY')
export GEMINI_API_KEY=$(fish -c 'echo $GEMINI_API_KEY')
export MOONSHOT_API_KEY=$(fish -c 'echo $MOONSHOT_API_KEY')
```
