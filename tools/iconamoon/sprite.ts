// The web's IconaMoon sprite and its name list, from the vendored SVGs: one
// <symbol> per icon named like the icon, an alias repeating its parent.
// usage: sprite.ts <svg dir> <aliases.json> <sprite out> <names out>
const [dir, aliasesPath, spriteOut, namesOut] = Deno.args

const bodies = new Map<string, string>()
for await (const entry of Deno.readDir(dir!)) {
  if (!entry.name.endsWith('.svg')) continue
  const svg = await Deno.readTextFile(`${dir}/${entry.name}`)
  const body = /^<svg [^>]*viewBox="0 0 24 24">(.*)<\/svg>\n$/s.exec(svg)?.[1]
  if (body == null) throw new Error(`${entry.name} is not a 24×24 icon`)
  bodies.set(entry.name.slice(0, -'.svg'.length), body)
}
const aliases = JSON.parse(await Deno.readTextFile(aliasesPath!)) as Record<
  string,
  string
>
for (const [alias, parent] of Object.entries(aliases)) {
  const body = bodies.get(parent)
  if (body == null) throw new Error(`${alias} names a missing ${parent}`)
  bodies.set(alias, body)
}
const names = [...bodies.keys()].sort()
await Deno.writeTextFile(
  spriteOut!,
  [
    '<svg xmlns="http://www.w3.org/2000/svg">',
    '<!-- IconaMoon by Dariush Habibpour (https://github.com/dariushhpg1/IconaMoon), CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). From @iconify-json/iconamoon 1.2.2: every icon of all six styles as a symbol named like the icon; an alias repeats its parent. Nothing else is changed. -->',
    ...names.map((name) =>
      `<symbol id="${name}" viewBox="0 0 24 24">${bodies.get(name)}</symbol>`
    ),
    '</svg>',
    '',
  ].join('\n'),
)
await Deno.writeTextFile(namesOut!, JSON.stringify(names) + '\n')
