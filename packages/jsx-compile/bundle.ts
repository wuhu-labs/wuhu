#!/usr/bin/env -S deno run --allow-all
const status = await new Deno.Command(Deno.execPath(), {
  args: [
    'bundle',
    '--frozen',
    '--no-remote',
    '--node-modules-dir=none',
    '--format',
    'iife',
    '--platform',
    'browser',
    '--minify',
    'src/compile.ts',
    '--output',
    'compile.js',
  ],
  stdout: 'inherit',
  stderr: 'inherit',
}).spawn().status
if (!status.success) Deno.exit(status.code)
