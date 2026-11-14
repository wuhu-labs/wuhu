#!/usr/bin/env -S deno run --allow-all
await Deno.mkdir('shell-sdk', { recursive: true })
for await (const entry of Deno.readDir('app/lib/shell-sdk')) {
  await Deno.copyFile(
    `app/lib/shell-sdk/${entry.name}`,
    `shell-sdk/${entry.name}`,
  )
}
