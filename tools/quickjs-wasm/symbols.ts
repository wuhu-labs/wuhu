const source = await Deno.readTextFile(Deno.args[0])
const declarations = source.matchAll(
  /^([\w()* ]+[\s*]+)(QTS_\w+)(\((.*?)\)) ?\{$/gm,
)
const symbols = [...declarations]
  .filter((match) => !/AsyncifyOnly|DebugOnly/.test(match[1]))
  .map((match) => `_${match[2]}`)
await Deno.writeTextFile(
  Deno.args[1],
  JSON.stringify([...symbols, '_malloc', '_free']),
)
