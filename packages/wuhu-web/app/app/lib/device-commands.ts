import type { QueryOutput } from './contract.gen.ts'

export interface DeviceCommand {
  n: number
  payload: unknown
  issuedAt: number
}

export const commandStalenessMs = 15_000

// The window is part of the query and re-evaluated server-side on every re-run,
// so a connect never ships the device's whole command history.
export function deviceCommandsSQL(device: string): string {
  return `SELECT n, payload, created_at FROM device_commands
WHERE device_id = '${device.replaceAll("'", "''")}'
  AND created_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-60 seconds')
ORDER BY n`
}

export function deviceCommands(output: QueryOutput): DeviceCommand[] {
  return output.rows.map(([n, payload, createdAt]) => ({
    n: Number(n),
    payload: JSON.parse(String(payload)),
    issuedAt: Date.parse(String(createdAt)),
  }))
}

// A command is a live gesture on a screen someone is watching: it plays in
// issue order, at most once per tab, and never after it has gone cold. Only a
// `sidebar` string is this client's vocabulary; anything else is skipped.
export function playCommands(
  commands: readonly DeviceCommand[],
  played: number,
  now: number,
): { played: number; sidebar: string | null } {
  let sidebar: string | null = null
  for (const command of [...commands].sort((a, b) => a.n - b.n)) {
    if (command.n <= played) continue
    played = command.n
    const requested = (command.payload as { sidebar?: unknown } | null)
      ?.sidebar
    if (
      now - command.issuedAt <= commandStalenessMs &&
      typeof requested === 'string'
    ) {
      sidebar = requested
    }
  }
  return { played, sidebar }
}
