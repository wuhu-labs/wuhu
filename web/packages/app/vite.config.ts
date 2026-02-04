import { reactRouter } from '@react-router/dev/vite'
import { resolveDenoImports } from '@wuhu/react-router-deno/resolver'

export default {
  plugins: [resolveDenoImports(), reactRouter()],
  ssr: {
    target: 'webworker',
  },
  build: {
    target: 'esnext',
  },
}
