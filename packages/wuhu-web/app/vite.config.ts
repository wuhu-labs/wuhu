import babel from '@babel/core'
import { reactRouter } from '@react-router/dev/vite'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig, type Plugin } from 'vite'

// vite-plugin-babel 1.7 breaks rolldown-vite 8's napi transform cache, so we
// run the compiler through a plain transform hook ourselves.
function reactCompiler(): Plugin {
  return {
    name: 'react-compiler',
    async transform(code, id) {
      if (!/\/app\/.*\.[jt]sx?$/.test(id)) return null
      const result = await babel.transformAsync(code, {
        filename: id,
        babelrc: false,
        configFile: false,
        presets: ['@babel/preset-typescript'],
        plugins: ['babel-plugin-react-compiler'],
        sourceMaps: true,
      })
      if (!result?.code) return null
      return { code: result.code, map: result.map }
    },
  }
}

export default defineConfig({
  plugins: [tailwindcss(), reactRouter(), reactCompiler()],
  resolve: {
    tsconfigPaths: true,
  },
  // Every path outside /_/ names a space file, so the SPA's own files live
  // under the reserved prefix.
  build: {
    assetsDir: '_/assets',
  },
  server: {
    proxy: {
      '/v1': {
        target: 'https://127.0.0.1:5540',
        // The upstream is the space server's self-signed TLS cert.
        secure: false,
        changeOrigin: true,
        ws: false,
        proxyTimeout: 0,
        timeout: 0,
        // Node parks response headers until the first body write, so a
        // header-only SSE response (observe from=head, no events yet) never
        // reaches the browser. Flush the head once http-proxy has copied the
        // upstream headers — the proxyRes event fires before its writeHead.
        configure(proxy) {
          proxy.on('proxyRes', (_proxyRes, _req, res) => {
            setImmediate(() => {
              if (!res.writableEnded) res.flushHeaders()
            })
          })
        },
      },
    },
  },
})
