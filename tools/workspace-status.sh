#!/usr/bin/env bash
set -euo pipefail

# A pool job's slot sits at the merge base plus the submitted patch, so its own
# HEAD and dirtiness are not the submitter's; the executor exports the
# submitting checkout as WUHU_CHECKOUT_* (packages/build-pool/src/workspace.ts).
# Its dirty bit follows `git status`, so untracked-only files (which the pool
# really builds) stamp -dirty, unlike local `git describe --dirty`.
if [ -n "${WUHU_CHECKOUT_COMMIT:-}" ]; then
  describe="${WUHU_CHECKOUT_DESCRIBE:-}"
  if [ -n "${describe}" ] && [ "${WUHU_CHECKOUT_DIRTY:-0}" = 1 ]; then
    describe="${describe}-dirty"
  fi
  commit="${WUHU_CHECKOUT_COMMIT}"
else
  describe="$(git describe --tags --dirty --match 'wuhu/v*' 2>/dev/null || true)"
  commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
fi
if [ -n "${describe}" ]; then
  version="${describe#wuhu/v}"
else
  version="0.0.0-untagged"
fi
if [ "${1:-}" = --release-tag ]; then
  if [ "$#" -ne 2 ] || ! [[ "$2" =~ ^wuhu/v[0-9]+\.[0-9]+\.[0-9]+(-(dev|beta)\.[0-9]+)?$ ]]; then
    echo "invalid release tag" >&2
    exit 64
  fi
  version="${2#wuhu/v}"
fi

echo "STABLE_WUHU_VERSION ${version}"
echo "STABLE_WUHU_COMMIT ${commit}"
echo "WUHU_BUILD_DATE $(date -u +%Y-%m-%d)"
