#!/usr/bin/env bash
set -euo pipefail
files=()
while IFS= read -r file; do files+=("$file"); done < "@@FILES@@"
expected=(@@EXPECTED@@)
((${#files[@]})) || exit 0
status=0
output="$("@@SWIFTLINT@@" lint --strict --quiet --no-cache --config "@@CONFIG@@" -- "${files[@]}" 2>&1)" || status=$?
[[ -z "$output" ]] || printf '%s\n' "$output"
((${#expected[@]})) || exit "$status"
if ((status != 2)); then
  echo "expected lint to fail with violations of: ${expected[*]} (exit $status)" >&2
  exit 1
fi
for rule in "${expected[@]}"; do
  grep -qF "($rule)" <<<"$output" || { echo "expected a $rule violation" >&2; exit 1; }
done
