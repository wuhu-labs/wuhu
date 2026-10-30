import { dirname, join, relative, resolve } from '@std/path'

export interface CTargetLowering {
  module: string
  fetch: { url: string; sha256: string; stripPrefix?: string }
  sources: string[]
  publicHeader?: string
  publicHeadersPath?: string
  patches?: { path: string; strip: number }[]
  exclude?: string[]
  defines?: string[]
  headerSearchPaths?: string[]
  unsafeFlags?: string[]
  cxxStandard?: 'c++17'
  linuxLibraries?: string[]
}

function confinedPath(path: string): void {
  if (
    typeof path !== 'string' || !path ||
    /[\\\s:"]/.test(path) ||
    [...path].some((char) =>
      char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127
    ) ||
    path.split('/').some((part) => !part || part === '.' || part === '..')
  ) {
    throw new Error(
      `Expected a confined relative path: ${JSON.stringify(path)}`,
    )
  }
}

// tar listings escape controls with backslashes on both GNU tar and BSD tar.
function confinedArchivePath(path: string): void {
  if (
    !path || path.includes('\\') ||
    [...path].some((char) =>
      char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127
    ) ||
    path.split('/').some((part) => !part || part === '.' || part === '..')
  ) {
    throw new Error(`Unsafe archive path: ${JSON.stringify(path)}`)
  }
}

export function validateCTarget(c: CTargetLowering): void {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(c.module)) {
    throw new Error(`Invalid cTarget module: ${c.module}`)
  }
  if ((c.publicHeader !== undefined) === (c.publicHeadersPath !== undefined)) {
    throw new Error(
      'cTarget requires exactly one of publicHeader or publicHeadersPath',
    )
  }
  for (
    const path of [
      c.publicHeader ?? c.publicHeadersPath!,
      ...c.sources,
      ...(c.exclude ?? []),
      ...(c.headerSearchPaths ?? []),
      ...(c.fetch.stripPrefix === undefined ? [] : [c.fetch.stripPrefix]),
    ]
  ) confinedPath(path)
  if (c.cxxStandard !== undefined && c.cxxStandard !== 'c++17') {
    throw new Error(`Unsupported cTarget cxxStandard: ${c.cxxStandard}`)
  }
  const paths = new Set<string>()
  for (const patch of c.patches ?? []) {
    confinedPath(patch.path)
    if (!Number.isSafeInteger(patch.strip) || patch.strip < 0) {
      throw new Error(`Invalid patch strip count: ${patch.strip}`)
    }
    if (paths.has(patch.path)) throw new Error(`Duplicate patch: ${patch.path}`)
    paths.add(patch.path)
  }
}

function requiresPublicHeaderMaterialization(header: string): boolean {
  return !header.startsWith('include/')
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    bytes as Uint8Array<ArrayBuffer>,
  )
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

async function remove(path: string): Promise<void> {
  try {
    await Deno.remove(path, { recursive: true })
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error
  }
}

async function regularPath(root: string, path: string): Promise<string> {
  const resolved = await Deno.realPath(join(root, path))
  const rel = relative(await Deno.realPath(root), resolved)
  confinedPath(rel)
  return resolved
}

async function command(
  cmd: string,
  args: string[],
  cwd?: string,
): Promise<string> {
  const result = await new Deno.Command(cmd, {
    args,
    cwd,
    ...(cmd === 'tar' ? { env: { TAR_OPTIONS: '' } } : {}),
    stdout: 'piped',
    stderr: 'piped',
  }).output()
  if (!result.success) {
    throw new Error(
      `${cmd} failed: ${new TextDecoder().decode(result.stderr)}${
        new TextDecoder().decode(result.stdout)
      }`,
    )
  }
  return new TextDecoder().decode(result.stdout)
}

// Do not let git's permissive patch parser select an unchecked alternate path.
function validatePatch(text: string, strip: number): void {
  let headers = 0
  let oldLines = 0
  let newLines = 0
  for (const line of text.split('\n')) {
    if (oldLines || newLines) {
      if (line.startsWith('\\')) continue
      if (line.startsWith(' ') || line.startsWith('-')) oldLines--
      if (line.startsWith(' ') || line.startsWith('+')) newLines--
      if (!/^[ +\-]/.test(line) || oldLines < 0 || newLines < 0) {
        throw new Error('Malformed unified patch hunk')
      }
      continue
    }
    const hunk = /^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/.exec(line)
    if (hunk) {
      oldLines = Number(hunk[1] ?? 1)
      newLines = Number(hunk[2] ?? 1)
    } else if (line.startsWith('--- ') || line.startsWith('+++ ')) {
      const path = line.slice(4).split('\t')[0]!
      if (path === '/dev/null') continue
      confinedPath(path)
      confinedPath(path.split('/').slice(strip).join('/'))
      headers++
    } else if (
      /^(?:GIT binary patch|Binary files |(?:old|new) mode |(?:new|deleted) file mode (?!100644$|100755$)|rename |copy )/
        .test(line)
    ) {
      throw new Error('Only regular-file unified text patches are supported')
    }
  }
  if (oldLines || newLines) throw new Error('Incomplete unified patch hunk')
  if (!headers) throw new Error('Expected a unified text patch')
}

export async function ensureUpstreamCheckout(
  packageDir: string,
  c: CTargetLowering,
  fetchArchive: (url: string) => Promise<Uint8Array> = async (url) => {
    const response = await fetch(url)
    if (!response.ok) {
      throw new Error(`fetching ${url} failed: HTTP ${response.status}`)
    }
    return new Uint8Array(await response.arrayBuffer())
  },
): Promise<void> {
  validateCTarget(c)
  const parent = resolve(packageDir, '.upstream')
  await Deno.mkdir(parent, { recursive: true })
  if ((await Deno.lstat(parent)).isSymlink) {
    throw new Error('.upstream must not be a symlink')
  }
  const dir = join(parent, c.module)
  const marker = join(dir, '.materialized-sha256')
  const lock = `${dir}.lock`
  await Deno.mkdir(lock)
  let stage: string | undefined
  try {
    let previous: string | undefined
    try {
      if ((await Deno.lstat(dir)).isSymlink) {
        throw new Error('cTarget checkout must not be a symlink')
      }
      previous = await Deno.readTextFile(marker)
    } catch (error) {
      if (!(error instanceof Deno.errors.NotFound)) throw error
    }
    // A missing or newly-invalid patch must not leave a reusable old checkout.
    await remove(marker)
    await remove(join(dir, '.fetched-sha256'))
    const patches: {
      path: string
      strip: number
      bytes: Uint8Array
      sha256: string
    }[] = []
    for (const patch of c.patches ?? []) {
      const path = await regularPath(packageDir, patch.path)
      const bytes = await Deno.readFile(path)
      const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
      validatePatch(text, patch.strip)
      patches.push({ ...patch, bytes, sha256: await sha256(bytes) })
    }
    const identity = await sha256(new TextEncoder().encode(JSON.stringify({
      schema: 1,
      fetch: c.fetch,
      publicHeader: c.publicHeader,
      publicHeadersPath: c.publicHeadersPath,
      patches: patches.map(({ path, strip, sha256 }) => ({
        path,
        strip,
        sha256,
      })),
    })))
    if (previous === identity) {
      await Deno.writeTextFile(marker, identity)
      return
    }
    stage = await Deno.makeTempDir({
      dir: parent,
      prefix: `${c.module}.stage-`,
    })
    const archive = join(stage, 'archive.tar.gz')
    const bytes = await fetchArchive(c.fetch.url)
    if (await sha256(bytes) !== c.fetch.sha256) {
      throw new Error(`sha256 mismatch for ${c.fetch.url}`)
    }
    await Deno.writeFile(archive, bytes)
    const entries = (await command('tar', ['-tzf', archive])).replace(/\n$/, '')
      .split(
        '\n',
      )
    for (const entry of entries) {
      const path = entry.replace(/\/$/, '')
      confinedArchivePath(path)
      if (
        c.fetch.stripPrefix && path !== c.fetch.stripPrefix &&
        !path.startsWith(`${c.fetch.stripPrefix}/`)
      ) {
        throw new Error(`Archive entry does not match stripPrefix: ${entry}`)
      }
    }
    const listing = await command('tar', ['-tvzf', archive])
    if (
      listing.replace(/\n$/, '').split('\n').some((line) => !/^[-d]/.test(line))
    ) {
      throw new Error(
        'Archive must contain only regular files and directories (no links)',
      )
    }
    const tree = join(stage, 'tree')
    await Deno.mkdir(tree)
    await command('tar', [
      '-xzf',
      archive,
      '-C',
      tree,
      '--no-same-owner',
      '--no-same-permissions',
      ...(c.fetch.stripPrefix
        ? ['--strip-components', String(c.fetch.stripPrefix.split('/').length)]
        : []),
    ])
    for (const [index, patch] of patches.entries()) {
      const input = join(stage, `patch-${index}`)
      await Deno.writeFile(input, patch.bytes)
      await command('git', [
        '-c',
        'apply.ignoreWhitespace=false',
        'apply',
        '--no-index',
        '--whitespace=nowarn',
        `-p${patch.strip}`,
        input,
      ], tree)
    }
    if (c.publicHeader) {
      const header = await regularPath(tree, c.publicHeader)
      if (!(await Deno.stat(header)).isFile) {
        throw new Error('publicHeader must be a regular file')
      }
      if (requiresPublicHeaderMaterialization(c.publicHeader)) {
        const destination = join(tree, 'include', c.publicHeader)
        await Deno.mkdir(dirname(destination), { recursive: true })
        await Deno.copyFile(header, destination)
      }
    }
    const headers = await regularPath(tree, c.publicHeadersPath ?? 'include')
    if (!(await Deno.stat(headers)).isDirectory) {
      throw new Error('publicHeadersPath must be a directory')
    }
    await Deno.writeTextFile(join(tree, '.materialized-sha256'), identity)
    const backup = join(stage, 'previous')
    let hadPrevious = false
    try {
      await Deno.rename(dir, backup)
      hadPrevious = true
    } catch (error) {
      if (!(error instanceof Deno.errors.NotFound)) throw error
    }
    try {
      await Deno.rename(tree, dir)
    } catch (error) {
      if (hadPrevious) await Deno.rename(backup, dir)
      throw error
    }
  } finally {
    if (stage) await remove(stage)
    await remove(lock)
  }
}
