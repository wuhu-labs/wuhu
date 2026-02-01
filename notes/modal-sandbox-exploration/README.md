# Modal Sandbox Exploration Notes

## Overview

Modal's TypeScript SDK allows creating sandboxes - secure, isolated containers that boot in seconds. Useful for running arbitrary code, custom daemons, or creating dev environments.

## Installation

```bash
bun add modal
```

Requires Node 22+ (or Bun). Auth via `MODAL_TOKEN_ID` and `MODAL_TOKEN_SECRET` env vars.

## Basic Usage

```typescript
import { ModalClient } from "modal";

const modal = new ModalClient({
  tokenId: process.env.MODAL_TOKEN_ID,
  tokenSecret: process.env.MODAL_TOKEN_SECRET,
});

const app = await modal.apps.fromName("my-app", { createIfMissing: true });
const image = modal.images.fromRegistry("alpine:3.21");

const sb = await modal.sandboxes.create(app, image, {
  command: ["sleep", "infinity"],
  idleTimeoutMs: 3600000,  // 1 hour idle timeout
  timeoutMs: 7200000,      // 2 hour max timeout
});

// Execute commands
const proc = await sb.exec(["echo", "hello"]);
console.log(await proc.stdout.readText());

// Cleanup
await sb.terminate();
```

## Tunnels & Ports

Three port types available:

| Type | Use Case |
|------|----------|
| `encryptedPorts` | HTTPS-wrapped (TLS) |
| `unencryptedPorts` | Raw TCP (for SSH, etc.) |
| `h2_ports` | HTTP/2 |

```typescript
const sb = await modal.sandboxes.create(app, image, {
  command: ["python3", "-m", "http.server", "3000"],
  encryptedPorts: [3000],
});

const tunnels = await sb.tunnels();
// tunnels[3000].url -> https://...
```

For raw TCP (e.g., SSH):

```typescript
const sb = await modal.sandboxes.create(app, image, {
  command: ["sleep", "infinity"],
  unencryptedPorts: [22],
});

const tunnels = await sb.tunnels();
// tunnels[22].unencryptedHost -> "r444.modal.host"
// tunnels[22].unencryptedPort -> 12345 (dynamic port)
```

## Idle Timeout Behavior

Activity that resets idle timeout:
- Active `sb.exec()` commands
- Writing to `sb.stdin`
- Open TCP connections through tunnels

Note: Internal process activity (CPU work, background jobs) does NOT count as activity.

## PID 1 Constraint

Modal runs its own init (`dumb-init`) as PID 1:

```
PID   USER     COMMAND
  1   root     /bin/dumb-init -- sleep infinity
  2   root     sleep infinity
  4   root     /__modal/.bin/modal-daemon ...
```

**Implications:**
- Your command runs as a child process, not PID 1
- Images requiring PID 1 (s6-overlay, systemd) won't work
- Custom entrypoints are ignored - you specify `command` explicitly

**What works:**
- Base images (alpine, ubuntu, python, node)
- Services started via `sb.exec()`
- Supervisord/runit (don't require PID 1)

**What doesn't work:**
- `linuxserver/*` images (use s6-overlay)
- Any image expecting its ENTRYPOINT to be PID 1

## Reconnecting to Sandboxes

```typescript
// By ID
const sb = await modal.sandboxes.fromId("sb-xxxxx");

// By name (if created with name option)
const sb = await modal.sandboxes.fromName("my-app", "my-sandbox-name");
```

Note: No way to reconnect to individual `exec()` processes. Only the sandbox itself.

## Auth for Custom Daemons

**Option 1: Modal's connect token (port 8080 only)**
```typescript
const creds = await sb.createConnectToken();
// Use creds.url + Authorization: Bearer ${creds.token}
```

**Option 2: Roll your own (any port)**
```typescript
const sb = await modal.sandboxes.create(app, image, {
  command: ["my-server", "--port", "3000"],
  encryptedPorts: [3000],
});
const tunnels = await sb.tunnels();
// tunnels[3000].url -> your server, add your own auth layer
```

WebSocket works fine over encrypted tunnels.

## Running Multiple Daemons

Options:
1. **sleep + exec**: Simple, no supervision
2. **supervisord**: Process management, restart on crash
3. **runit**: Lightweight alternative

```typescript
// Option 1: Manual
const sb = await modal.sandboxes.create(app, image, { command: ["sleep", "infinity"] });
await sb.exec(["daemon1", "--foreground"]);  // don't await .wait()
await sb.exec(["daemon2", "--foreground"]);

// Option 2: Supervisord as main command
const sb = await modal.sandboxes.create(app, image, {
  command: ["supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"],
});
```
