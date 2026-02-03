# AGENTS.md

## What is Wuhu

Wuhu is a data layer + API for understanding coding agents. Not a task runner -
a session log collector and query system.

Core value: collect logs from Claude Code, Codex, OpenCode, etc. Provide APIs so
agents can query them. Git blame a line → find the session → understand the why.

See `notes/architecture-vibe.md` for full architecture discussion.

## Deployed URLs

- **Web UI**: https://wuhu.liu.ms
- **API**: https://api.wuhu.liu.ms

## Project Structure

```
.
├── core/                    # Backend (Deno)
│   ├── packages/
│   │   ├── server/          # Hono API server
│   │   ├── sandbox-daemon/  # Sandbox runtime
│   │   └── prisma/          # Database client (@wuhu/prisma)
│   ├── prisma/              # Prisma schema & config
│   │   ├── schema/          # .prisma files
│   │   └── prisma.config.ts
│   ├── Dockerfile
│   └── deno.json            # Workspace root
├── web/                     # Frontend (Deno + React Router)
│   ├── packages/
│   │   └── app/             # React Router app
│   └── Dockerfile
├── deploy/                  # Kubernetes manifests
│   ├── core.yaml
│   └── web.yaml
└── .github/workflows/
    ├── ci.yml               # Lint, typecheck, tests
    └── deploy.yml           # Build & deploy to k3s
```

## Development Environment

You're running in a self-hosted Terragon instance. The original Terragon product
is dead - no commercial future, no data retrieval from the old hosted version.

## Core Tasks (Deno)

Run from `core/`:

```bash
deno task verify          # Typecheck + lint + tests
deno task check           # Typecheck only
deno task test            # Run tests
deno task coverage        # Generate coverage report
deno task coverage:check  # Fail if below threshold (default 80%)
```

Override coverage threshold: `COVERAGE_MIN=0.7 deno task coverage:check`

## Prisma (Database)

Prisma runs via Node (using `npx`) but generates a Deno-compatible client.

Run from `core/`:

```bash
deno task prisma:gen      # Generate client to packages/prisma/generated/
deno task prisma:push     # Push schema to database (dev)
```

Or directly from `core/prisma/`:

```bash
DATABASE_URL="postgresql://user@localhost/wuhu_dev" npx prisma generate
DATABASE_URL="postgresql://user@localhost/wuhu_dev" npx prisma db push
DATABASE_URL="postgresql://user@localhost/wuhu_dev" npx prisma migrate dev
```

The generated client lives at `core/packages/prisma/generated/` (gitignored).
Import via `@wuhu/prisma`:

```ts
import { createPrismaClient } from '@wuhu/prisma'
const prisma = createPrismaClient()
```

## Docker

Build images locally:

```bash
docker build -t wuhu-core:test ./core
docker build -t wuhu-web:test ./web
```

Run locally (needs postgres):

```bash
docker run --rm -e DATABASE_URL="postgresql://user@host.docker.internal/wuhu_dev" \
  -p 3000:3000 wuhu-core:test
```

The core Dockerfile uses a multi-stage build:
1. **Node stage**: Runs `prisma generate` (Node 24)
2. **Build stage**: Deno install + typecheck
3. **Production stage**: Deno runtime only (no Node)

## Deployment

Deployed to a self-hosted k3s cluster via GitHub Actions (`.github/workflows/deploy.yml`).

**Trigger**: Push to `main` or manual `workflow_dispatch`

**Flow**:
1. Build Docker image with commit SHA tag
2. Import to k3s containerd
3. Apply k8s manifests from `deploy/`
4. Rolling update deployment

**Monitor**:

```bash
kubectl get pods
kubectl get deployments
kubectl logs -l app=core
kubectl describe pod -l app=core
```

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on PRs and pushes to `main`.

**Steps**:
1. Setup Deno + Node 24
2. Generate Prisma client
3. Push schema to test database (postgres service container)
4. Lint, typecheck, test for both `core/` and `web/`

The CI uses a postgres service container - no external database needed.

## Reference Paths

These paths are available in the Terragon dev environment:

- `.` - Wuhu repo (this repo)
- `../wuhu-terragon` - Terragon source code, always available
- `../axiia-website` - Personal project with useful code patterns (Bun-based)
- `../codex` - OpenAI Codex repo, for integration experiments
- `../pi-mono` - Pi coding agent monorepo, reference harness

The `terragon-setup.sh` script clones these repos before your environment starts.

## Using Terragon Code

Terragon has working implementations of:

- Sandbox providers (E2B, Docker, Daytona)
- Daemon (agent runtime)
- GitHub integration (PRs, checkpoints, webhooks)
- Real-time updates (PartyKit)
- Web UI patterns

Reference it freely. Copy and adapt what makes sense. But Wuhu has different
goals - don't inherit Terragon's tight coupling.

## Key Differences from Terragon

Terragon: "agents do your coding tasks" - full product, tightly integrated Wuhu:
"understand your coding agents" - data layer, composition-first, modular

Wuhu principles:

- Expose primitives via API/MCP, let agents compose
- Small interfaces, easy mocks
- GitHub-optional (mock locally, polling for no-domain setups)
- Infrastructure-agnostic contracts

## Reference Projects

### Axiia Website (`../axiia-website`)

Personal project (paideia-ai/axiia-website). Bun monorepo with Elysia server,
React Router SSR, service registry pattern, and domain API layering. Useful
patterns for API design, DI, and config management. See `notes/axiia-website.md`
for details.

## Notes

Architecture discussions live in `notes/`:

- `architecture-vibe.md` - overall system design
- `session-logs-component.md` - first component spec
- `axiia-website.md` - reference project notes
