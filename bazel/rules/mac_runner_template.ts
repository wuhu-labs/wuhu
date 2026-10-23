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
