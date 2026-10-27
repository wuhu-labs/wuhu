---
name: script-runtime
description: Use run_script runtime facilities — authenticated fetch and static module imports.
---

# Script runtime

fetch(url, { identity: true }) sends a per-call 60 s server-signed JWT for your space/group/session, aud = target origin (verify the issuer’s /.well-known/jwks.json); identity must be boolean, defaults off, conflicts with Authorization (invalidArgument), and never follows cross-origin hops with the token or falls back on signing failure (fetchIdentityUnavailable); token masking in responses/output is best-effort (split/encoded echoes may reach JavaScript); the security guarantee is aud bound to the named origin plus the 60 s lifetime, so an echoed token works only against a server you can already reach with identity: true.

Static imports of space files (`import { x } from "wuhu:/skills/tool/lib.js"`) and read-only system files (`import { x } from "wuhu://system/<path>"`) read as of script start: 1 MiB per file, 256 files. Relative `./` and `../` imports stay on their originating side.

`sleep(ms, { signal? })` rejects when the supplied signal aborts. Use the global `signal` to tie work to cancellation or the lifetime limit.
