# Wuhu MVP Architecture

## Philosophy

- Composition over integration - expose primitives, let agents compose
- Small interfaces, easy mocks - UI dev doesn't need real sandboxes
- Infrastructure-agnostic contracts - "I need a cache" not "I need Redis"

## Infrastructure

- **Runtime:** Deno
- **RDBMS:** Postgres (handles FTS, vectors, everything)
- **Cache:** Redis
- **Object Storage:** Minio (S3-compatible)
- **Orchestration:** Self-hosted k3s
- **Ingress:** Traefik

## Sandbox Architecture

**Pivot: Self-hosted k3s** (Modal/3rd-party sandbox work on hold)

Reason: Jobs need direct access to internal services (MCP servers). Running in
our own k3s cluster avoids exposing internal services externally.

### Sandbox = K8s Job

- Runs forever until manually killed via web UI (MVP)
- No auto-termination for now

### Job Lifecycle

1. Job starts with setup script as entrypoint
2. Setup script downloads bundled daemon from internal cluster service
3. Setup script installs Pi agent
4. Setup script starts daemon in background
5. Setup script loops checking for sentinel file (`/tmp/shutdown`)
6. On shutdown: daemon receives kill signal → writes sentinel file → exits
7. Loop sees file → script exits → Job completes

```bash
#!/bin/sh
# download daemon from internal service
curl -o daemon http://internal-service/daemon
# install pi agent
...

# start daemon in background
./daemon &

# wait for exit signal
while [ ! -f /tmp/shutdown ]; do
  sleep 1
done
```

### Daemon

- Agent runtime inside the Job
- Runs its own HTTP API (control plane)
- Spawns preview server for port exposure
- Configured with endpoints from Controller
- Doesn't know or care about deployment mode

## Preview URL Routing

- Pattern: `<sandbox-id>-<port>.wuhu.liu.ms`
- Uses existing `*.wuhu.liu.ms` DNS/cert (no infra changes)

**Current implementation (MVP):**
- In-band JS proxy in core server
- Wildcard ingress routes `*.wuhu.liu.ms` → core
- Core parses host, looks up pod IP, proxies request

**Deferred: Traefik Plugin**

TODO: If preview traffic becomes a bottleneck, move routing to a Traefik plugin:
- Go plugin loaded in-process by Traefik (via Yaegi interpreter)
- Plugin logic:
  1. Parse host: extract sandbox ID + port from `<id>-<port>.wuhu.liu.ms`
  2. Call core service for pod IP lookup: `GET http://core/sandbox-lookup?id=<id>`
  3. Proxy request to `<pod-ip>:<port>`
- Removes core from the preview traffic path

## K8s API Access

- Use `kubernetes-models` npm package for types (no SDK bloat)
- Plain fetch to K8s API
- Read service account token from `/var/run/secrets/kubernetes.io/serviceaccount/token`
- Hit API at `https://kubernetes.default.svc`

## Data Flow

### Turn Definition

A turn means: human message → AI tool call loop → AI final summary (no more tools)

### Split State

1. **UI State (Postgres)** - converted messages/tool calls for display, with cursor
2. **Raw Logs (Minio)** - full Pi agent session logs, uploaded after each turn

### SSE Resume Flow

1. React Router loader fetches messages from DB up to cursor
2. Browser starts SSE from cursor → web app → sandbox daemon
3. No gaps, no duplicates

### Future Concern (Deferred)

Cloud sandboxes won't have direct access to internal API. Options for later:
- Public ingress endpoint
- Message queue
- WebSocket tunnel

MVP uses in-cluster direct calls.
