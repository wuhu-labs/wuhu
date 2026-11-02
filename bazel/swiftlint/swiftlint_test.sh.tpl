#!/usr/bin/env bash
set -euo pipefail
files=()
while IFS= read -r file; do files+=("$file"); done < "@@FILES@@"
expected=(@@EXPECTED@@)
((${#files[@]})) || exit 0
status=0
output="$("@@SWIFTLINT@@" lint --force-exclude --strict --quiet --no-cache --config "@@CONFIG@@" -- "${files[@]}" 2>&1)" || status=$?
[[ -z "$output" ]] || printf '%s\n' "$output"
((${#expected[@]})) || exit "$status"
if ((status != 2)); then
  echo "expected lint to fail with violations of: ${expected[*]} (exit $status)" >&2
  exit 1
fi
# A rule listed n times must report at least n violations.
for rule in $(printf '%s\n' "${expected[@]}" | sort -u); do
  want=$(printf '%s\n' "${expected[@]}" | grep -cxF -- "$rule")
  got=$(grep -cF -- "($rule)" <<<"$output" || true)
  ((got >= want)) || { echo "expected $want $rule violation(s), got $got" >&2; exit 1; }
done
