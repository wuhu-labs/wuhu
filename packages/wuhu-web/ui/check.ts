#!/usr/bin/env -S deno run --allow-all
await Deno.mkdir('src/shared', { recursive: true })
await Deno.copyFile(
  '../../widget-script-kit/Targets/WidgetScriptSource/Sources/Resources/allowance.json',
  'src/shared/allowance.json',
)
for (
  const args of [
    ['install', '--frozen', '--cached-only'],
    ['check', '--frozen', '--no-remote', 'src'],
  ]
) {
  const status = await new Deno.Command(Deno.execPath(), {
    args,
    stdout: 'inherit',
    stderr: 'inherit',
  }).spawn().status
  if (!status.success) Deno.exit(status.code)
}
