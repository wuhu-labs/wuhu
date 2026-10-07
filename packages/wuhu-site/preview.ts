import { buildGuide } from './guide.ts'

const pages = await buildGuide()
const port = Number(Deno.args[0] ?? '8099')
Deno.serve({ hostname: '127.0.0.1', port }, async (request) => {
  const path = decodeURIComponent(new URL(request.url).pathname).slice(1)
  const guide = pages.get(path.endsWith('/') ? `${path}index.html` : path)
  if (guide) {
    return new Response(guide, {
      headers: { 'content-type': 'text/html; charset=utf-8' },
    })
  }
  const files = new Map([
    ['', 'index.html'],
    ['index.html', 'index.html'],
    ['privacy', 'privacy.html'],
    ['terms', 'terms.html'],
    ['support', 'support.html'],
    ['install.sh', 'install.sh'],
  ])
  const file = files.get(path)
  if (!file) return new Response('Not found', { status: 404 })
  return new Response(await Deno.readFile(new URL(file, import.meta.url)), {
    headers: {
      'content-type': file.endsWith('.html')
        ? 'text/html; charset=utf-8'
        : 'text/plain; charset=utf-8',
    },
  })
})
