<!-- deno-fmt-ignore-file -->

# Partial history web proof

The baseline was built from `48eaba31b`; the after build is the web partial-loading slice. Both were served by a Bazel-built `//packages/wuhu-core:wuhu` on isolated TLS ports 5571/5572, against fresh scratch spaces. Chrome used controlled HTTP page fixtures and cancellable `ReadableStream` SSE fixtures in the actual product SPA; this is client viewport/projection proof, **not** proof of the new server storage implementation. Server bounded-read/authorization/adapter proof belongs to the integration lead. No live user history was accessed or changed. A self-signed certificate prevented service-worker registration in Chrome; the warnings are recorded and service-worker/offline-shell behavior is not claimed here.

The rendered `reference.svg` is the signed loading-surface placement mockup, retained from the issue. Desktop and compact captures preserve existing product styling, with centered history controls inside the scrolling content, a 44px minimum action target, and the existing jump pill while reading away from the tail. CI separately checks six accessible HTML snapshot references under `app/lib/history-edge-snapshots/`; those are markup goldens, not pixel-diff tests.

## Reproduce

Use only a clean, assigned M4 checkout. Build baseline and after bundles in that checkout, not another agent's working copy. The baseline bundle captured in this run was preserved through a temporary local stash, then the original changes were restored; on a clean review branch the equivalent commands are:

```sh
ROOT=/tmp/wuhu105-proof
mkdir -p "$ROOT/baseline-app" "$ROOT/current-app"
git switch --detach 48eaba31b
(cd packages/wuhu-web/app && deno install && deno task build)
cp -R packages/wuhu-web/app/build/client/. "$ROOT/baseline-app/"
git switch -
(cd packages/wuhu-web/app && deno install && deno task build)
cp -R packages/wuhu-web/app/build/client/. "$ROOT/current-app/"
bazel build //packages/wuhu-core:wuhu
```

Run these servers in separate owned terminals; never use or stop ports 5530/5540:

```sh
.bazel/bin/packages/wuhu-core/wuhu serve /tmp/wuhu105-proof/space-before --port 5571 --dev --web-app /tmp/wuhu105-proof/baseline-app
.bazel/bin/packages/wuhu-core/wuhu serve /tmp/wuhu105-proof/space-after --port 5572 --dev --web-app /tmp/wuhu105-proof/current-app
```

```sh
cp packages/wuhu-web/app/proof/wuhu-105/{proof.mjs,reference.svg} /tmp/wuhu105-proof/
(cd /tmp/wuhu105-proof && npm install playwright-core && node proof.mjs)
bazel test //packages/wuhu-web/app:test //packages/wuhu-web/app:typecheck //packages/wuhu-web/app:lint //packages/wuhu-web/app:fmt
```

`PROOF_ROOT`, `BASELINE_PORT`, and `CURRENT_PORT` can relocate scratch artifacts and listeners. The installed Chrome is used; there is no browser download or additional repository dependency. The script asserts the actual navigation uses HTTP/2, no initial/layout-driven page cascade, one in-flight backward load, live append plus prepend anchoring, delayed 120px height growth, desktop/compact anchors, manual keyboard retry/exhaustion, and Preparing-to-ready. It captures baseline conversation/transcript, loading/manual/retry/exhaustion states on both sizes, the viewport during prepend, and the rendered signed reference. `captures/proof.json` records exact page queries and stable row coordinates. Ordinary reconnect/gaps/cache eviction/reset/stale generation/epoch races and partial origin joins are deterministic SDK/projection tests under the Bazel web test target.

## Final run measurements

All visible-anchor errors were below one CSS pixel: desktop message `message-100`, 280.921875→281.296875 after prepend/live append and 281.6875 after delayed height measurement; compact message, 268.59375→268.96875; desktop transcript `1:201:0`, 320.515625→320.390625; compact transcript `1:181:0`, 341.125→340.9375. `PROOF PASS` is the final script verdict. Captures and the proof log are supplied as transient review evidence and an attachment archive; they are not production assets or an automated native proof.
