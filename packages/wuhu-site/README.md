# wuhu.ai

The page at `https://wuhu.ai`: `index.html`, `install.sh`, the privacy, terms and support pages, and the English and Chinese operator guide. `icon/` holds the icon campaign's artifacts and is not deployed. Imported with its history from `wuhu-labs/wuhu-ai-site` at `735c3e9`.

A `main` push that touches this package deploys it to the R2 bucket behind wuhu.ai; the key list, caching and the rules the deploy keeps are in `docs/release.md` ("The wuhu.ai page"). `deno task ci:deploy-site --dry-run` from the repo root prints what a deploy would write.

The page names no version: it reads `/releases/beta/latest.json` at load. `install.sh` follows the same pointer; `WUHU_LANE` and `WUHU_VERSION` pick another lane or version. `deno task test` here runs `install.sh` against a local stand-in for the bucket.

## Operator guide

`docs/en/` and `docs/zh/` are the guide's source of truth. Edit the Markdown through PRs; do not edit generated HTML. `guide.ts` renders all twelve pages at deploy time, strips title frontmatter, rewrites space-era `/guide/...md` links, and validates every in-guide page and fragment link before anything uploads. Styling and code-copy controls are inlined from `guide.css` and `guide.js`; no client-side framework or external assets are needed.

`/docs` and `/zh/docs` are the canonical first page, with `docs/index.html` and `zh/docs/index.html` aliases for fronts that append `index.html` to a trailing slash; the twelve named pages use extensionless URLs. Each page links to its counterpart in the other language. `deno task preview` serves the generated guide and homepage on `http://127.0.0.1:8099`; pass a port to use another. Restart after edits. `deno task test` also tests the compiler, links, language switch destinations, and copyable code.
