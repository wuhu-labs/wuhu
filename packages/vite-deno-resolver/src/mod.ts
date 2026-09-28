import { isAbsolute } from '@std/path'
import { resolveSpecifier } from './core.ts'
import { loadWorkspace } from './workspace.ts'
import type { ResolverWorkspace } from './core.ts'

export type { Resolution, ResolverPackage, ResolverWorkspace } from './core.ts'
export { resolveSpecifier } from './core.ts'
export { loadWorkspace } from './workspace.ts'

export interface DenoResolverOptions {
  root: string
  // Peer packages to bundle into an SSR build instead of externalizing. CSS is
  // always inlined; a component library usually should be too.
  inlinePeers?: string[]
}

interface VitePlugin {
  name: string
  enforce?: 'pre' | 'post'
  config?: (config: unknown, env: { command: string }) => void
  resolveId?: (
    source: string,
    importer: string | undefined,
    options?: { ssr?: boolean },
  ) => Promise<string | { id: string; external?: boolean } | null>
}

export function denoResolver(options: DenoResolverOptions): VitePlugin {
  const inlinePeers = new Set(options.inlinePeers ?? [])
  let workspace: ResolverWorkspace | null = null
  let loading: Promise<ResolverWorkspace> | null = null
  let isDev = false

  const load = async (): Promise<ResolverWorkspace> => {
    if (workspace) return workspace
    loading ??= loadWorkspace(options.root)
    workspace = await loading
    return workspace
  }

  return {
    name: 'wuhu:deno-resolver',
    enforce: 'pre',
    config(_config, env) {
      isDev = env.command === 'serve'
    },
    async resolveId(source, importer, resolveOptions) {
      if (source.startsWith('\0') || source.includes('virtual:')) return null
      if (importer?.includes('node_modules')) return null
      const importerPath = importer && isAbsolute(importer)
        ? importer
        : `${options.root}/`
      const resolution = resolveSpecifier(await load(), source, importerPath)
      if (resolution === null || resolution.kind === 'npm') return null
      if (resolution.kind === 'local') return { id: resolution.path }
      const inline = isDev ||
        !resolveOptions?.ssr ||
        inlinePeers.has(resolution.packageName) ||
        resolution.path.endsWith('.css')
      return { id: resolution.path, external: !inline }
    },
  }
}
