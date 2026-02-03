import {
  createRequestHandler,
  RouterContextProvider,
  type ServerBuild,
} from 'react-router'

const BUILD_PATH = './build/server/index.js'
const PORT = parseInt(process.env.PORT ?? '3000')

const serverBuild: ServerBuild = await import(BUILD_PATH)
const requestHandler = createRequestHandler(serverBuild, 'production')

// Serve static assets
const clientDir = new URL('./build/client', import.meta.url).pathname

Bun.serve({
  port: PORT,
  async fetch(request) {
    const url = new URL(request.url)

    // Serve static assets from /assets
    if (url.pathname.startsWith('/assets/')) {
      const filePath = `${clientDir}${url.pathname}`
      const file = Bun.file(filePath)
      if (await file.exists()) {
        return new Response(file, {
          headers: {
            'cache-control': 'public, max-age=31536000, immutable',
          },
        })
      }
    }

    // Handle all other routes with React Router
    try {
      const routerContext = new RouterContextProvider()
      return await requestHandler(request, routerContext)
    } catch (error) {
      console.error('Error handling request:', error)
      return new Response('<h1>Something went wrong</h1>', {
        status: 500,
        headers: { 'Content-Type': 'text/html' },
      })
    }
  },
})

console.log(`Server running on http://localhost:${PORT}`)
