const server = Deno.serve(
  { hostname: '127.0.0.1', port: 0 },
  async (request) => {
    const name = new URL(request.url).pathname.slice(1)
    if (
      name !== 'emscripten-module.browser.mjs' &&
      name !== 'emscripten-module.wasm'
    ) {
      return new Response(null, { status: 404 })
    }
    const body = await Deno.readFile(new URL(name, import.meta.url))
    return new Response(body, {
      headers: {
        'content-type': name.endsWith('.wasm')
          ? 'application/wasm'
          : 'text/javascript',
      },
    })
  },
)
const worker = new Worker(new URL('./smoke-worker.ts', import.meta.url).href, {
  type: 'module',
})
try {
  await new Promise<void>((resolve, reject) => {
    worker.onmessage = (event) =>
      event.data.error ? reject(new Error(event.data.error)) : resolve()
    worker.onerror = (event) => reject(new Error(event.message))
    worker.postMessage(
      `http://127.0.0.1:${server.addr.port}/emscripten-module.browser.mjs`,
    )
  })
  console.log(
    'quickjs-ng 0.15.1 + quickjs-emscripten-core 0.32.0: smoke passed',
  )
} finally {
  worker.terminate()
  await server.shutdown()
}
