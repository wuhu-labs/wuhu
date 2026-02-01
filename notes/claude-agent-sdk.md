# Claude Agent SDK Exploration

## Package Overview

- **NPM Package**: `@anthropic-ai/claude-agent-sdk`
- **Current Version**: 0.2.29
- **Depends on**: `@anthropic-ai/claude-code` (bundled CLI, version 2.1.29)

## How It Works

The SDK spawns the Claude Code CLI (`claude`) as a subprocess with `--print --output-format stream-json --verbose` flags and communicates via stdin/stdout JSON streaming.

## Installation

```bash
bun add @anthropic-ai/claude-agent-sdk
# or
npm install @anthropic-ai/claude-agent-sdk
```

## Basic Usage

```typescript
import { query } from "@anthropic-ai/claude-agent-sdk";

for await (const message of query({
  prompt: "What is 2 + 2?",
  options: {
    allowedTools: ["Read", "Glob", "Grep"],
    permissionMode: "default",  // or "bypassPermissions" (not as root!)
    maxTurns: 5,
  },
})) {
  if (message.type === "system" && message.subtype === "init") {
    console.log("Session ID:", message.session_id);
  }
  if ("result" in message) {
    console.log("Result:", message.result);
  }
}
```

## Message Types Yielded

1. **system** (subtype: "init") - Session initialization with tools, model, etc.
2. **assistant** - Claude's responses with `message.content`
3. **result** (subtype: "success") - Final result with `result` field

## Session Logs

Sessions are persisted to disk at:
```
~/.claude/projects/<encoded-project-path>/<session-id>.jsonl
```

Each line is a JSON object:
- `type`: "queue-operation", "user", "assistant"
- `sessionId`: UUID for the session
- `uuid`: UUID for each message
- `parentUuid`: Links messages in a chain
- `message`: The actual content
- `timestamp`: ISO timestamp
- `version`: Claude Code version

Session index at `~/.claude/projects/<path>/sessions-index.json`.

## Package Structure (claude-code)

```
@anthropic-ai/claude-code (68MB)
├── cli.js           (11MB) - Single bundled/minified JS
├── sdk-tools.d.ts   (67KB) - TypeScript types for SDK tools
├── resvg.wasm       (2.5MB) - SVG rendering
├── tree-sitter*.wasm (1.5MB) - Code parsing
└── vendor/ripgrep/  (55MB) - Multiplatform binaries
    ├── arm64-darwin/
    ├── arm64-linux/
    ├── x64-darwin/
    ├── x64-linux/
    └── x64-win32/
```

## Multiplatform Strategy

1. **Ripgrep**: Ships ALL platform binaries in package (~55MB). Runtime selects based on `process.platform`/`process.arch`.

2. **Sharp** (image processing): Uses npm `optionalDependencies` with `os`/`cpu`/`libc` constraints - only matching platform is downloaded.

3. **WebAssembly**: tree-sitter and resvg use .wasm files (architecture-agnostic).

## Key Options

```typescript
interface ClaudeAgentOptions {
  allowedTools?: string[];           // ["Read", "Edit", "Bash", "Task", ...]
  permissionMode?: "default" | "bypassPermissions" | "acceptEdits" | "plan";
  maxTurns?: number;                 // Max API round-trips
  mcpServers?: Record<string, McpServerConfig>;
  agents?: Record<string, AgentDefinition>;  // Custom subagents
  resume?: string;                   // Session ID to resume
  pathToClaudeCodeExecutable?: string;  // Custom CLI path (optional)
  settingSources?: ("user" | "project" | "local")[];
}
```

## Gotchas

- `bypassPermissions` doesn't work when running as root
- SDK requires matching claude-code version (check `claudeCodeVersion` in package.json)
- The SDK automatically finds the bundled CLI - no need to set `pathToClaudeCodeExecutable`
