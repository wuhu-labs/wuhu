// A script that never imports wuhu:machine still finds no way to the host:
// the prelude deleted its host functions and link hooks, and wuhu:machine,
// evaluated before the script, took the internals the prelude left it.
const left = Object.getOwnPropertyNames(globalThis).filter((name) => name.startsWith("__wuhu"))
result(`left on globalThis: ${JSON.stringify(left)}`)
