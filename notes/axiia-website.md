# Axiia Website

Personal project at `paideia-ai/axiia-website`. Available at `../axiia-website`
after running `terragon-setup.sh`.

## What It Is

A Bun monorepo for the Axiia platform - an education/assessment platform with:

- Elysia server with React Router SSR
- Multiple web apps (main, reports, test)
- Service registry pattern with DI
- Prisma for database
- AWS SSM integration for config

## Useful Patterns

### Architecture

- **Domain API layering**: 3-layer structure (Imperative `*Api` → REST → SDK)
- **Service registry**: Clean separation between interface definitions and
  implementations
- **Subdomain routing**: Routes to different apps based on subdomain

### Packages of Interest

- `packages/api` + `packages/api-infra` - Domain interfaces + Prisma
  implementations
- `packages/services` + `packages/service-*` - Service contracts and DI
- `packages/server` - Elysia + React Router SSR host
- `packages/toolkit` - Shared utilities

### Tooling

- Bun workspaces
- oxfmt/oxlint (fast Rust-based formatting/linting)
- tsgo for type builds
- Linear integration

## Relevance to Wuhu

- API layering pattern could inform Wuhu's query API design
- Service registry pattern aligns with Wuhu's "small interfaces, easy mocks"
  principle
- Config management approach (YAML + AWS SSM) for infrastructure-agnostic setup
