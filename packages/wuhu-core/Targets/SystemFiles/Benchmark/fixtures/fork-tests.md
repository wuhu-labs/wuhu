# Fork test route

Run from a monorepo slot: `deno task pool fork-test tca26 <full-lowercase-pushed-SHA> [-- --filter <regex> --skip <regex>]`. Only tca26 (wuhu-labs/tca26) is approved initially. Only filter/skip arguments are admitted; there is no shell, package-path or compiler-flag route. Push first; no uncommitted patch or submitter credentials transfer. Infra pushes fork commits through the existing GitHub workflow.

The Mac executor freshly fetches the fork with its read-only deploy key, verifies remote reachability, runs its own SwiftPM tests under pinned Xcode, streams logs and returns `.wuhu/pool-artifacts/<job>/fork-test.xml`. A filter matching zero tests is red. Source and build scratch are deleted; per-slot dependency caches are capped at 2 GiB retained. Do not run SwiftPM locally on devbox. Monorepo Bazel tests are not the fork's own suite.
