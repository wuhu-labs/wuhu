// Shared subprocess helpers. One failure policy: a nonzero exit throws (so
// callers' try/finally cleanup runs), and every command echoes `$ cmd` first
// so logs — including the release ldd check — show what ran.

export async function run(
  command: string[],
  cwd?: string,
  env?: Record<string, string>,
): Promise<void> {
  console.log(`$ ${command.join(' ')}`)
  const status = await new Deno.Command(command[0]!, {
    args: command.slice(1),
    cwd,
    env,
    stdin: 'inherit',
    stdout: 'inherit',
    stderr: 'inherit',
  }).spawn().status
  if (!status.success) {
    throw new Error(`command failed (${status.code}): ${command.join(' ')}`)
  }
}

export async function output(
  command: string[],
  cwd?: string,
  env?: Record<string, string>,
): Promise<string> {
  console.log(`$ ${command.join(' ')}`)
  const result = await new Deno.Command(command[0]!, {
    args: command.slice(1),
    cwd,
    env,
    stderr: 'inherit',
    stdout: 'piped',
  }).output()
  if (!result.success) {
    throw new Error(`command failed (${result.code}): ${command.join(' ')}`)
  }
  return new TextDecoder().decode(result.stdout)
}

export async function tryOutput(command: string[]): Promise<string | null> {
  const result = await new Deno.Command(command[0]!, {
    args: command.slice(1),
    stderr: 'piped',
    stdout: 'piped',
  }).output()
  if (!result.success) return null
  return new TextDecoder().decode(result.stdout)
}
