// usage: deno run --allow-read --allow-write tools/iconamoon/apple.ts
const root = 'packages/wuhu-app/Targets/CommonUI/Sources/IconaMoon.xcassets'
const aliases = JSON.parse(
  await Deno.readTextFile('tools/iconamoon/aliases.json'),
) as Record<string, string>
const icons = new Map<string, string>()
for await (const entry of Deno.readDir('tools/iconamoon/svg')) {
  if (entry.name.endsWith('.svg')) {
    icons.set(
      entry.name.slice(0, -4),
      await Deno.readTextFile(`tools/iconamoon/svg/${entry.name}`),
    )
  }
}
for (const [name, parent] of Object.entries(aliases)) {
  icons.set(name, icons.get(parent)!)
}
await Deno.mkdir(root, { recursive: true })
await Deno.writeTextFile(
  `${root}/Contents.json`,
  JSON.stringify({ info: { author: 'xcode', version: 1 } }) + '\n',
)
for (const [name, svg] of [...icons].sort(([a], [b]) => a.localeCompare(b))) {
  const dir = `${root}/${name}.imageset`
  await Deno.mkdir(dir, { recursive: true })
  await Deno.writeTextFile(
    `${dir}/icon.svg`,
    svg.replaceAll('currentColor', '#000000'),
  )
  await Deno.writeTextFile(
    `${dir}/Contents.json`,
    JSON.stringify({
      images: [{ filename: 'icon.svg', idiom: 'universal' }],
      info: { author: 'xcode', version: 1 },
      properties: {
        'preserves-vector-representation': true,
        'template-rendering-intent': 'template',
      },
    }) + '\n',
  )
}
