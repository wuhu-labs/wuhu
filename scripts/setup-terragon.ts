import { join } from '@std/path'

async function pathExists(path: string): Promise<boolean> {
  try {
    await Deno.lstat(path)
    return true
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return false
    }
    throw error
  }
}

async function runGit(args: string[], cwd: string): Promise<void> {
  const command = new Deno.Command('git', {
    cwd,
    args,
    stdout: 'inherit',
    stderr: 'inherit',
  })
  const child = command.spawn()
  const status = await child.status
  if (!status.success) {
    throw new Error(
      `git ${args.join(' ')} failed in ${cwd} with code ${status.code}`,
    )
  }
}

async function getTerragonRemote(baseDir: string): Promise<string> {
  const existingTerragon = join(baseDir, 'wuhu-terragon')
  if (await pathExists(existingTerragon)) {
    const command = new Deno.Command('git', {
      cwd: existingTerragon,
      args: ['remote', 'get-url', 'origin'],
      stdout: 'piped',
      stderr: 'inherit',
    })
    const child = command.spawn()
    const output = await child.output()
    if (output.success) {
      const url = new TextDecoder().decode(output.stdout).trim()
      if (url.length > 0) {
        return url
      }
    }
  }
  // Fallback to the public snapshot of Terragon
  return 'https://github.com/paideia-ai/wuhu.git'
}

async function ensureTerragonClones(baseDir: string): Promise<void> {
  const remote = await getTerragonRemote(baseDir)

  const primaryDir = join(baseDir, 'wuhu-terragon')
  if (!(await pathExists(primaryDir))) {
    console.log(`Cloning Terragon into ${primaryDir}...`)
    await runGit(['clone', remote, 'wuhu-terragon'], baseDir)
  }

  const aliasDir = join(baseDir, 'terrragon')
  if (!(await pathExists(aliasDir))) {
    console.log(`Cloning Terragon alias into ${aliasDir}...`)
    await runGit(['clone', remote, 'terrragon'], baseDir)
  }
}

async function ensureCodexClone(baseDir: string): Promise<void> {
  const dir = join(baseDir, 'codex')
  if (await pathExists(dir)) {
    return
  }
  console.log(`Cloning openai/codex into ${dir}...`)
  await runGit(
    ['clone', 'https://github.com/openai/codex.git', 'codex'],
    baseDir,
  )
}

async function ensurePiMonoClone(baseDir: string): Promise<void> {
  const dir = join(baseDir, 'pi-mono')
  if (await pathExists(dir)) {
    return
  }
  console.log(`Cloning badlogic/pi-mono into ${dir}...`)
  await runGit(
    ['clone', 'https://github.com/badlogic/pi-mono.git', 'pi-mono'],
    baseDir,
  )
}

async function ensureAxiiaWorktrees(baseDir: string): Promise<void> {
  const repoDir = join(baseDir, 'axiia-website')
  const remote = 'https://github.com/paideia-ai/axiia-website.git'

  if (!(await pathExists(repoDir))) {
    console.log(`Cloning axiia-website into ${repoDir}...`)
    await runGit(['clone', remote, 'axiia-website'], baseDir)
  }

  console.log('Updating axiia-website main worktree...')
  await runGit(['fetch', 'origin'], repoDir)
  await runGit(['checkout', 'main'], repoDir)
  await runGit(['pull', '--ff-only', 'origin', 'main'], repoDir)

  const denoWorktreeDir = join(baseDir, 'axiia-website-deno')
  const denoCommit = 'df170fe8'

  if (!(await pathExists(denoWorktreeDir))) {
    console.log(
      `Creating axiia-website-deno worktree at commit ${denoCommit}...`,
    )
    await runGit(
      ['worktree', 'add', denoWorktreeDir, denoCommit],
      repoDir,
    )
  }
}

async function main() {
  const cwd = Deno.cwd()
  const baseDir = join(cwd, '..')

  await Promise.all([
    ensureTerragonClones(baseDir),
    ensureCodexClone(baseDir),
    ensurePiMonoClone(baseDir),
    ensureAxiiaWorktrees(baseDir),
  ])
}

if (import.meta.main) {
  await main()
}
