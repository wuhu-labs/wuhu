#!/bin/bash

set -uo pipefail

test_env_inherit=%(test_env_inherit)s

export DENO_DIR="${TEST_TMPDIR:-${TMPDIR:-/tmp}}/deno-dir"
export DENO_NO_UPDATE_CHECK=1

exec "$PWD/%(deno)s" run \
  --no-config \
  --no-lock \
  --allow-read \
  --allow-write \
  --allow-env \
  --allow-sys=userInfo,uid,gid \
  --allow-run=/usr/bin/xcrun,/usr/bin/xcode-select,/bin/cp,/usr/bin/unzip \
  "$PWD/%(runner)s" \
  --lane "%(lane)s" \
  --platform-dir "%(platform_dir)s" \
  --bundle "%(test_bundle_path)s" \
  --filter "%(test_filter)s" \
  --env "%(test_env)s" \
  -- ${test_env_inherit[@]+"${test_env_inherit[@]}"}
