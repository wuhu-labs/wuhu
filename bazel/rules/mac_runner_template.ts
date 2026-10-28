export function macRunnerTemplate(
  source: string,
  inherited: string[],
  prelaunch: boolean,
): string {
  function replaceOnce(marker: string, replacement: string): void {
    const count = source.split(marker).length - 1
    if (count !== 1) {
      throw new Error(
        `pinned macOS runner template changed: expected one ${
          JSON.stringify(marker)
        }, found ${count}`,
      )
    }
    source = source.replace(marker, () => replacement)
  }
  const environment = 'TEST_ENV="%(test_env)s"'
  replaceOnce(environment, [environment, ...inherited].join('\n'))
  if (prelaunch) {
    const read = '  IFS== read key value <<< "$SINGLE_TEST_ENV"'
    replaceOnce(
      read,
      `${read}
  if [[ "$key" == WUHU_VDISPLAY_TOOL ]]; then
    if ! "$value" acquire; then
      echo "macOS capture display prelaunch acquisition failed: $value" >&2
      exit 1
    fi
  fi`,
    )
  }
  // The pinned runner ignores Bazel's --test_filter. xcodebuild selects only
  // through the xctestrun's ProductModuleName, and a selection matching nothing
  // passes silently, so an empty filtered run fails here.
  const launch = 'xcodebuild test-without-building \\'
  replaceOnce(
    launch,
    `selection=()
if [[ -n "\${TESTBRIDGE_TEST_ONLY:-}" ]]; then
  IFS=, read -r -a filters <<< "$TESTBRIDGE_TEST_ONLY"
  for filter in "\${filters[@]}"; do
    if [[ "$filter" == -* ]]; then
      selection+=("-skip-testing:BazelMacOSTests/\${filter:1}")
    else
      selection+=("-only-testing:BazelMacOSTests/$filter")
    fi
  done
fi
${launch}`,
  )
  const substitution =
    '  -e "s${sed_delim}BAZEL_TEST_ENVIRONMENT${sed_delim}$XCTESTRUN_ENV${sed_delim}g" \\'
  replaceOnce(
    substitution,
    `${substitution}
  -e "s\${sed_delim}<key>TestBundlePath</key>\${sed_delim}<key>ProductModuleName</key><string>\${TEST_BUNDLE_NAME//-/_}</string><key>TestBundlePath</key>\${sed_delim}" \\`,
  )
  const xctestrun = '    -xctestrun "$XCTESTRUN" \\'
  replaceOnce(
    xctestrun,
    `${xctestrun}
    \${selection[@]+"\${selection[@]}"} \\`,
  )
  const status = '    || test_exit_code=$?'
  replaceOnce(
    status,
    `${status}
if [[ \${#selection[@]} -gt 0 && "$test_exit_code" -eq 0 ]] &&
  ! grep -qE '(Executed|Test run with) [1-9][0-9]* tests?' "$testlog"; then
  echo "error: --test_filter=$TESTBRIDGE_TEST_ONLY selected no tests" >&2
  exit 1
fi`,
  )
  return source
}

if (import.meta.main) {
  const [input, output, inheritedJSON, prelaunch] = Deno.args
  if (
    !input || !output || !inheritedJSON ||
    !['true', 'false'].includes(prelaunch)
  ) {
    throw new Error(
      'usage: mac_runner_template input output inherited-json prelaunch',
    )
  }
  const source = await Deno.readTextFile(input)
  await Deno.writeTextFile(
    output,
    macRunnerTemplate(source, JSON.parse(inheritedJSON), prelaunch === 'true'),
  )
}
