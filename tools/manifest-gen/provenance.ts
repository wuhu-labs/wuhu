const manifestNames = new Set([
  'MODULE.fragment.bazel',
  'app.yml',
  'deno.json',
  'package.yml',
  'target.yml',
])

async function exists(path: string): Promise<boolean> {
  try {
    await Deno.stat(path)
    return true
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false
    throw error
  }
}

// Paths under `dir`, relative to `root`.
async function filesUnder(
  root: string,
  dir: string,
  include: (name: string) => boolean = () => true,
): Promise<string[]> {
  const files: string[] = []
  if (!await exists(`${root}/${dir}`)) return files
  for await (const entry of Deno.readDir(`${root}/${dir}`)) {
    const path = `${dir}/${entry.name}`
    if (entry.isDirectory) {
      files.push(...await filesUnder(root, path, include))
    } else if (entry.isFile && include(entry.name)) {
      files.push(path)
    }
  }
  return files
}

// Every file the generator reads, relative to the repo root: a change to any
// of them makes the generated manifests stale.
export async function manifestInputPaths(root = '.'): Promise<string[]> {
  const fixed = [
    'MODULE.bazel.template',
    'bazel/umbrella/Package.resolved',
    'deno.json',
    'deno.lock',
  ]
  // Signing identities stay in the monorepo; a tree exported without them
  // generates no signed app shells and so has nothing here to fingerprint.
  const optional = ['tools/signing/signing.yml']
  const present: string[] = []
  for (const path of optional) {
    if (await exists(`${root}/${path}`)) present.push(path)
  }
  return [
    ...fixed,
    ...present,
    ...await filesUnder(root, 'bazel/umbrella/configure'),
    ...await filesUnder(root, 'tools/manifest-gen'),
    ...await filesUnder(root, 'tools/lib'),
    ...await filesUnder(root, 'packages', (name) => manifestNames.has(name)),
  ].sort()
}

export async function manifestFingerprint(): Promise<string> {
  const parts: BlobPart[] = []
  for (const path of await manifestInputPaths()) {
    const bytes = await Deno.readFile(path)
    parts.push(`${path}\0${bytes.byteLength}\0`, bytes)
  }
  const digest = await crypto.subtle.digest(
    'SHA-256',
    await new Blob(parts).arrayBuffer(),
  )
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

export async function manifestInputsNewerThan(stamp: string): Promise<boolean> {
  const stampTime = (await Deno.stat(stamp)).mtime?.getTime()
  if (stampTime === undefined) return true
  for (const path of await manifestInputPaths()) {
    const inputTime = (await Deno.stat(path)).mtime?.getTime()
    if (inputTime !== undefined && inputTime > stampTime) return true
  }
  return false
}

if (import.meta.main) {
  console.log(await manifestFingerprint())
  if (Deno.args[0] === '--newer-than') {
    if (Deno.args.length !== 2) {
      throw new Error('usage: provenance.ts --newer-than <stamp>')
    }
    console.log(
      await manifestInputsNewerThan(Deno.args[1]) ? 'newer' : 'current',
    )
  }
}
