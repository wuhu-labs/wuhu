---
name: web-search
description: Search the public web through a configured Brave, Exa or zero-setup Codex capability and return explicit sources.
---

# Web search

```js
import { webSearch } from 'wuhu:web_search'
result(await webSearch('the user’s question', { count: 8 }))
```

`webSearch(query, { provider?, count? })` (also the module's default export) returns `{ query, provider, sources: [{ title, url, snippet?, published? }], text? }`. Count is 1–20, default 8. Codex supplies cited answer text when available; source snippets and publication dates are omitted when unavailable. Calling search alone does not report the result: use `result`, `update`, or a user-requested file.

The space's `/capabilities.json` selects `web_search.active`; `provider` is an explicit configured variant override, not a key or URL. A missing capability synthesizes Codex using the existing ChatGPT login. Broken explicit configuration never spends another provider. The module is always importable. Failures are `CapabilityError` with `code`, `message`, `hint`: `provider_not_configured`, `provider_auth`, `provider_region`, `provider_entitlement`, `provider_rate_limited`, `unsupported_feature`, `invalid_argument`, `provider_unavailable`. Retry transient failures; explain setup/entitlement failures, or choose another configured provider only deliberately. Never configure credentials without authorization or put them in `wuhu:secret`.

Brave results may appear in the user's conversation or requested files. Do not build a persistent result corpus/index or use returned results for model training or evaluation. Synthetic offline protocol fixtures are not a search-result corpus.

CLI parity: `wuhu web-search 'the question' --count 8 [--provider brave]` prints the same normalized JSON. No region, offset, freshness, crawling or result-cache options are exposed in v1.
