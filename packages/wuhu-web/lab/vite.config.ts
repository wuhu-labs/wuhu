import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { denoResolver } from '@wuhu/vite-deno-resolver'
import { fromFileUrl } from '@std/path'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [
    denoResolver({
      root: fromFileUrl(new URL('..', import.meta.url)),
      inlinePeers: ['@wuhu/ui'],
    }),
    react(),
    tailwindcss(),
  ],
  server: {
    port: 5187,
    strictPort: true,
  },
})
