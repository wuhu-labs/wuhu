# wuhu.ai

The page at `https://wuhu.ai`: `index.html`, `install.sh` and the privacy, terms and support pages. `icon/` holds the icon campaign's artifacts and is not deployed. Imported with its history from `wuhu-labs/wuhu-ai-site` at `735c3e9`.

A `main` push that touches this package deploys it to the R2 bucket behind wuhu.ai; the key list, caching and the rules the deploy keeps are in `docs/release.md` ("The wuhu.ai page"). `deno task ci:deploy-site --dry-run` from the repo root prints what a deploy would write.

The page names no version: it reads `/releases/beta/latest.json` at load. `install.sh` follows the same pointer; `WUHU_LANE` and `WUHU_VERSION` pick another lane or version. `deno task test` here runs `install.sh` against a local stand-in for the bucket.
