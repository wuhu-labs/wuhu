export interface ResolverPackage {
  name?: string
  dir: string
  imports: Record<string, string>
  exports: Record<string, string>
}

export interface ResolverWorkspace {
  root: string
  packages: ResolverPackage[]
}

export type Resolution =
  | { kind: 'local'; path: string }
  | { kind: 'peer'; packageName: string; path: string }
  | { kind: 'npm'; specifier: string }

export function owningPackage(
  workspace: ResolverWorkspace,
  importerPath: string,
): ResolverPackage | null {
  let owner: ResolverPackage | null = null
  for (const candidate of workspace.packages) {
    if (!importerPath.startsWith(candidate.dir + '/')) continue
    if (owner === null || candidate.dir.length > owner.dir.length) {
      owner = candidate
    }
  }
  return owner
}

// Import-map semantics, not raw prefix matching: a bare key matches only an
// exact specifier, and only a trailing-slash key matches as a prefix. Raw
// startsWith would let an `imports` key `react` capture `react-dom`.
function mapSpecifier(
  imports: Record<string, string>,
  specifier: string,
): string | null {
  let match: string | null = null
  for (const key of Object.keys(imports)) {
    const applies = key.endsWith('/')
      ? specifier.startsWith(key)
      : specifier === key
    if (!applies) continue
    if (match === null || key.length > match.length) match = key
  }
  if (match === null) return null
  return imports[match]! + specifier.slice(match.length)
}

function resolvePeer(
  workspace: ResolverWorkspace,
  specifier: string,
): Resolution | null {
  let best: { pkg: ResolverPackage; subpath: string } | null = null
  for (const pkg of workspace.packages) {
    if (!pkg.name) continue
    const subpath = specifier === pkg.name
      ? '.'
      : specifier.startsWith(pkg.name + '/')
      ? '.' + specifier.slice(pkg.name.length)
      : null
    if (subpath === null) continue
    if (best === null || pkg.name.length > best.pkg.name!.length) {
      best = { pkg, subpath }
    }
  }
  if (best === null) return null
  const target = best.pkg.exports[best.subpath]
  if (target === undefined) {
    throw new Error(
      `${best.pkg.name} does not export ${best.subpath} (imported as ${specifier})`,
    )
  }
  return {
    kind: 'peer',
    packageName: best.pkg.name!,
    path: joinPath(best.pkg.dir, target),
  }
}

export function dropVersion(specifier: string): string {
  const parts = specifier.split('/')
  const nameIndex = parts[0]!.startsWith('@') ? 1 : 0
  if (parts.length <= nameIndex) return specifier
  parts[nameIndex] = parts[nameIndex]!.split('@')[0]!
  return parts.join('/')
}

function joinPath(dir: string, relative: string): string {
  const cleaned = relative.startsWith('./') ? relative.slice(2) : relative
  return `${dir}/${cleaned}`
}

// null means "not ours" — an ordinary npm specifier Vite resolves through
// node_modules. Throwing is reserved for a specifier that is ours and broken,
// so a misconfiguration cannot degrade silently into Vite's default resolution.
export function resolveSpecifier(
  workspace: ResolverWorkspace,
  specifier: string,
  importerPath: string,
): Resolution | null {
  if (specifier.startsWith('.') || specifier.startsWith('/')) return null
  if (specifier.startsWith('npm:')) {
    return { kind: 'npm', specifier: dropVersion(specifier.slice(4)) }
  }
  if (specifier.startsWith('jsr:')) {
    throw new Error(
      `jsr specifiers are not resolvable through vite: ${specifier}`,
    )
  }

  const owner = owningPackage(workspace, importerPath)
  if (owner === null) return null

  const mapped = mapSpecifier(owner.imports, specifier)
  if (mapped === null) return resolvePeer(workspace, specifier)
  if (mapped.startsWith('.')) {
    return { kind: 'local', path: joinPath(owner.dir, mapped) }
  }
  if (mapped.startsWith('npm:')) {
    return { kind: 'npm', specifier: dropVersion(mapped.slice(4)) }
  }
  if (mapped.startsWith('jsr:')) {
    throw new Error(
      `jsr specifiers are not resolvable through vite: ${specifier} -> ${mapped}`,
    )
  }
  return resolvePeer(workspace, mapped)
}
