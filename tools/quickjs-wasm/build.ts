#!/usr/bin/env -S deno run --allow-all
async function run(
  program: string,
  args: string[],
  env: Record<string, string> = {},
) {
  const status = await new Deno.Command(program, {
    args,
    env,
    stdin: 'null',
    stdout: 'inherit',
    stderr: 'inherit',
  }).spawn().status
  if (!status.success) Deno.exit(status.code)
}
const root = Deno.cwd()
const toolchain = `${root}/private/sdk/install`
const engine = `${root}/private/engine/quickjs-0.15.1`
const wrapper = `${root}/private/wrapper/quickjs-emscripten-0.32.0`
for (
  const [archive, destination] of [['quickjs.tar.gz', 'private/engine'], [
    'wrapper.tar.gz',
    'private/wrapper',
  ], [
    Deno.build.os === 'darwin' ? 'sdk-mac.tar.xz' : 'sdk-linux.tar.xz',
    'private/sdk',
  ]]
) {
  await Deno.mkdir(destination, { recursive: true })
  await run('tar', ['-xf', archive, '-C', destination])
}
await run('patch', [
  '-p1',
  '-d',
  engine,
  '-i',
  `${root}/../../bazel/patches/quickjs-pending-module-free.patch`,
])
await run('patch', [
  '-p1',
  '-d',
  wrapper,
  '-i',
  `${root}/interface-includes.patch`,
])
await Deno.mkdir('tmp/cache', { recursive: true })
await run(Deno.execPath(), [
  'run',
  '--no-config',
  '--cached-only',
  '--allow-read',
  '--allow-write=tmp',
  'symbols.ts',
  `${wrapper}/c/interface.c`,
  'tmp/symbols.json',
])
await run(Deno.execPath(), [
  'run',
  '--no-config',
  '--cached-only',
  '--allow-read',
  '--allow-write=tmp',
  'engine.ts',
  `${engine}/quickjs.c`,
  `${wrapper}/vendor/quickjs-ng-patches/0001-bellard-module-detection.patch`,
  'tmp/quickjs.c',
])
async function copy(source: string, destination: string) {
  const stat = await Deno.lstat(source)
  if (stat.isDirectory) {
    await Deno.mkdir(destination, { recursive: true })
    for await (const entry of Deno.readDir(source)) {
      await copy(`${source}/${entry.name}`, `${destination}/${entry.name}`)
    }
  } else if (stat.isFile) {
    await Deno.copyFile(source, destination)
  } else if (stat.isSymlink) {
    await Deno.symlink(await Deno.readLink(source), destination)
  } else {
    throw new Error(`Unsupported cache entry: ${source}`)
  }
}
await copy(`${toolchain}/emscripten/cache`, 'tmp/cache')
await Deno.writeTextFile(
  'tmp/emscripten-config',
  [
    `LLVM_ROOT = ${JSON.stringify(`${toolchain}/bin`)}`,
    `BINARYEN_ROOT = ${JSON.stringify(toolchain)}`,
    `NODE_JS = [${JSON.stringify('node')}]`,
    `CACHE = ${JSON.stringify(`${root}/tmp/cache`)}`,
  ].join('\n'),
)
const env = {
  EM_CONFIG: `${root}/tmp/emscripten-config`,
  EM_CACHE: `${root}/tmp/cache`,
  PYTHONDONTWRITEBYTECODE: '1',
}
const emcc = `${toolchain}/emscripten/emcc.py`
const common = [
  `-ffile-prefix-map=${engine}=quickjs`,
  '-ffile-prefix-map=tmp/quickjs.c=quickjs/quickjs.c',
  '-fno-strict-aliasing',
  '-fomit-frame-pointer',
  '-Oz',
  '-funsigned-char',
  '-D_GNU_SOURCE',
  '-I',
  engine,
]
const objects: string[] = []
for (
  const [index, source] of [
    'tmp/quickjs.c',
    `${engine}/dtoa.c`,
    `${engine}/libregexp.c`,
    `${engine}/libunicode.c`,
    `${engine}/quickjs-libc.c`,
    `${wrapper}/c/interface.c`,
  ].entries()
) {
  const output = `tmp/${index}.o`
  await run('python3', [
    emcc,
    ...common,
    ...(index >= 4 ? ['-DQTS_USE_QUICKJS_NG', '-Wno-unused-variable'] : []),
    '-c',
    source,
    '-o',
    output,
  ], env)
  objects.push(output)
}
await run(`${toolchain}/bin/llvm-ar`, [
  'rcsD',
  'tmp/libengine.a',
  ...objects.slice(0, 4),
])
await run('python3', [
  emcc,
  ...objects.slice(4),
  'tmp/libengine.a',
  '-fno-strict-aliasing',
  '-sPRINTF_LONG_DOUBLE=1',
  '-Oz',
  '--no-entry',
  '-sMODULARIZE=1',
  '-sIMPORTED_MEMORY=1',
  '-sEXPORT_NAME=QuickJSRaw',
  '-sEXPORT_ES6=1',
  '-sENVIRONMENT=web,worker',
  '-sINVOKE_RUN=0',
  '-sALLOW_MEMORY_GROWTH=1',
  '-sALLOW_TABLE_GROWTH=1',
  '-sSTACK_SIZE=5MB',
  '-sSUPPORT_ERRNO=0',
  '-sFILESYSTEM=0',
  '-sEXPORTED_FUNCTIONS=@tmp/symbols.json',
  `-sEXPORTED_RUNTIME_METHODS=@${wrapper}/exportedRuntimeMethods.json`,
  '--pre-js',
  `${wrapper}/templates/pre-extension.js`,
  '--pre-js',
  `${wrapper}/templates/pre-wasmMemory.js`,
  '-o',
  'tmp/emscripten-module.js',
], env)
await Deno.copyFile(
  'tmp/emscripten-module.js',
  'emscripten-module.browser.mjs',
)
await Deno.copyFile(
  'tmp/emscripten-module.wasm',
  'emscripten-module.wasm',
)
