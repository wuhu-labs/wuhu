import {
  commandStalenessMs,
  type DeviceCommand,
  deviceCommands,
  deviceCommandsSQL,
  playCommands,
} from './device-commands.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const now = 1_800_000_000_000
const demo = '/.sidebars/demo.json'

const command = (n: number, payload: unknown, age = 0): DeviceCommand => ({
  n,
  payload,
  issuedAt: now - age,
})

Deno.test('rows decode into commands with their issue time', () => {
  equal(
    deviceCommands({
      columns: ['n', 'payload', 'created_at'],
      rows: [[4, '{"sidebar":"everything"}', '2026-09-27T01:02:03.500Z']],
    }),
    [{
      n: 4,
      payload: { sidebar: 'everything' },
      issuedAt: Date.parse('2026-09-27T01:02:03.500Z'),
    }],
  )
})

Deno.test('the device id is quoted into the query', () => {
  if (!deviceCommandsSQL("o'clock").includes("device_id = 'o''clock'")) {
    throw new Error('device id not quoted')
  }
})

Deno.test('a fresh command selects its sidebar', () => {
  equal(playCommands([command(1, { sidebar: demo })], 0, now), {
    played: 1,
    sidebar: demo,
  })
})

Deno.test('commands play in issue order whatever order they arrive in', () => {
  equal(
    playCommands(
      [
        command(2, { sidebar: 'everything' }),
        command(1, { sidebar: demo }),
      ],
      0,
      now,
    ),
    { played: 2, sidebar: 'everything' },
  )
})

Deno.test('a command past the window is dropped but still marked played', () => {
  equal(
    playCommands(
      [command(7, { sidebar: demo }, commandStalenessMs + 1)],
      0,
      now,
    ),
    { played: 7, sidebar: null },
  )
  equal(
    playCommands([command(1, { sidebar: demo }, commandStalenessMs)], 0, now),
    { played: 1, sidebar: demo },
  )
})

Deno.test('a redelivered command is not played twice', () => {
  equal(playCommands([command(1, { sidebar: demo })], 1, now), {
    played: 1,
    sidebar: null,
  })
})

Deno.test('vocabulary this client does not know is skipped', () => {
  equal(
    playCommands(
      [
        command(1, { theme: 'dark' }),
        command(2, { sidebar: 3 }),
        command(3, 'everything'),
        command(4, null),
      ],
      0,
      now,
    ),
    { played: 4, sidebar: null },
  )
})
