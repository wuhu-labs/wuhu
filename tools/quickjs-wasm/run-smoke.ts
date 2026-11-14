#!/usr/bin/env -S deno run --allow-all
for (const name of ['ffi', 'core', 'ffi-types']) {
  await Deno.mkdir(`facade/${name}`, { recursive: true })
  const status = await new Deno.Command('tar', {
    args: ['-xf', `${name}.tgz`, '-C', `facade/${name}`],
    stdout: 'inherit',
    stderr: 'inherit',
  }).spawn().status
  if (!status.success) Deno.exit(status.code)
}
await Deno.copyFile('facade/ffi/package/dist/ffi.mjs', 'ffi.mjs')
await Deno.copyFile('facade/ffi-types/package/dist/index.mjs', 'ffi-types.mjs')
await Deno.rename('facade/core/package/dist', 'core')
const status = await new Deno.Command(Deno.execPath(), {
  args: [
    'run',
    '--no-config',
    '--allow-read',
    '--allow-net=127.0.0.1',
    '--allow-import=127.0.0.1',
    '--import-map=imports.json',
    'smoke.ts',
  ],
  stdout: 'inherit',
  stderr: 'inherit',
}).spawn().status
if (!status.success) Deno.exit(status.code)
