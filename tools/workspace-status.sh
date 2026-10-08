#!/usr/bin/env bash
set -euo pipefail

describe="$(git describe --tags --dirty --match 'wuhu/v*' 2>/dev/null || true)"
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
commit="$(git rev-parse --short=9 HEAD 2>/dev/null || echo unknown)"

echo "STABLE_WUHU_VERSION ${version}"
echo "STABLE_WUHU_COMMIT ${commit}"
echo "WUHU_BUILD_DATE $(date -u +%Y-%m-%d)"
