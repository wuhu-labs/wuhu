#!/usr/bin/env -S deno run --allow-all
import { prepare } from '../prepare.ts'
const cache = await Deno.makeTempDir({ prefix: 'deno-cache-' })
await Deno.rename(Deno.env.get('DENO_DIR')!, `${cache}/dependencies`)
Deno.env.set('DENO_DIR', `${cache}/dependencies`)
await prepare()
const mode = Deno.args[0]
const commands = [
  ['install', '--frozen', '--cached-only'],
  ...(mode === 'bundle'
    ? [[
      'run',
      '--frozen',
      '--cached-only',
      '-A',
      'npm:@react-router/dev',
      'build',
    ]]
    : mode === 'typecheck'
    ? [[
      'run',
      '--frozen',
      '--cached-only',
      '-A',
      'npm:@react-router/dev',
      'typegen',
    ], [
      'run',
      '--frozen',
      '--cached-only',
      '-A',
      'npm:typescript/tsc',
      '-p',
      'tsconfig.check.json',
    ]]
    : [[
      'test',
      '--frozen',
      '--cached-only',
      '--sloppy-imports',
      '--allow-read',
      '--allow-env=NODE_ENV,WS_NO_BUFFER_UTIL',
      '--quiet',
      'app/lib',
      'app/sdk',
    ]]),
]
for (const args of commands) {
  const status = await new Deno.Command(Deno.execPath(), {
    args,
    stdout: 'inherit',
    stderr: 'inherit',
  }).spawn().status
  if (!status.success) Deno.exit(status.code)
}
