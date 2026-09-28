import { isAbsolute, join, resolve } from '@std/path'
import type { ResolverPackage, ResolverWorkspace } from './core.ts'

interface DenoManifest {
  name?: string
  workspace?: string[]
  links?: string[]
  imports?: Record<string, string>
  exports?: string | Record<string, string>
}

async function readManifest(dir: string): Promise<DenoManifest | null> {
  try {
    return JSON.parse(await Deno.readTextFile(join(dir, 'deno.json')))
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return null
    throw error
  }
}

function normalizeExports(
  exports: DenoManifest['exports'],
): Record<string, string> {
  if (exports === undefined) return {}
  return typeof exports === 'string' ? { '.': exports } : exports
}

function toPackage(dir: string, manifest: DenoManifest): ResolverPackage {
  return {
    name: manifest.name,
    dir,
    imports: manifest.imports ?? {},
    exports: normalizeExports(manifest.exports),
  }
}

// Members and links are both just peer packages with an absolute directory,
// which is the whole reason cross-workspace resolution needs no special case.
// Links are read one level deep: a link target that itself declares links is a
// dependency graph we have no reason to own yet.
export async function loadWorkspace(
  root: string,
): Promise<ResolverWorkspace> {
  if (!isAbsolute(root)) {
    throw new Error(`workspace root must be absolute: ${root}`)
  }
  const rootManifest = await readManifest(root)
  if (rootManifest === null) {
    throw new Error(`no deno.json at workspace root ${root}`)
  }

  const packages: ResolverPackage[] = []
  const seen = new Set<string>()
  const add = async (dir: string) => {
    const normalized = resolve(dir)
    if (seen.has(normalized)) return
    seen.add(normalized)
    const manifest = await readManifest(normalized)
    if (manifest === null) return
    packages.push(toPackage(normalized, manifest))
    return manifest
  }

  if (rootManifest.name || rootManifest.imports) {
    packages.push(toPackage(resolve(root), rootManifest))
    seen.add(resolve(root))
  }
  for (const member of rootManifest.workspace ?? []) {
    await add(join(root, member))
  }
  for (const link of rootManifest.links ?? []) {
    const target = await add(join(root, link))
    if (target?.links?.length) {
      throw new Error(
        `link target ${link} declares its own links; nested links are unsupported`,
      )
    }
    for (const member of target?.workspace ?? []) {
      await add(join(root, link, member))
    }
  }
  return { root: resolve(root), packages }
}
