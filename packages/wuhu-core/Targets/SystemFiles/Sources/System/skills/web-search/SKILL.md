---
name: web-search
description: Search the public web through a configured Brave, Exa or zero-setup Codex capability and return explicit sources.
script_exports: {"wuhu:web_search":["default","webSearch"]}
---

# Web search

```js
import { webSearch } from 'wuhu:web_search'
result(await webSearch('the user’s question', { count: 8 }))
```

`webSearch(query, { provider?, count? })` (also the module's default export) returns `{ query, provider, sources: [{ title, url, snippet?, published? }], text? }`. Count is 1–20, default 8. Codex supplies cited answer text when available; source snippets and publication dates are omitted when unavailable. Calling search alone does not report the result: use `result`, `update`, or a user-requested file.

Provider resolution, configuration-only probing and the re-exported `CapabilityError` contract are documented in [ai-scripts](wuhu://system/skills/ai-scripts/SKILL.md), Capability discovery. Never configure credentials without authorization.

Brave results may appear in the user's conversation or requested files. Do not build a persistent result corpus/index or use returned results for model training or evaluation. Synthetic offline protocol fixtures are not a search-result corpus.

CLI parity: `wuhu web-search 'the question' --count 8 [--provider brave]` prints the same normalized JSON. No region, offset, freshness, crawling or result-cache options are exposed in v1.
