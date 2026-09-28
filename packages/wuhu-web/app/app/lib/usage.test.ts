import type { ProviderDescriptor } from './contract.gen.ts'
import { usageCards, usageTone } from './usage.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const now = new Date('2026-09-27T12:00:00Z')
const seconds = (iso: string) => new Date(iso).getTime() / 1000

function provider(
  id: string,
  dialect: string,
  usage: ProviderDescriptor['usage'] = null,
): ProviderDescriptor {
  return { id, dialect, models: [], usage }
}

Deno.test('a plan the server has not observed is unobserved, never 0%', () => {
  const cards = usageCards([
    provider('codex', 'codex'),
    provider('claude', 'claude'),
  ], now)
  equal(cards, [
    { provider: 'codex', kind: 'unobserved' },
    { provider: 'claude', kind: 'unobserved' },
  ])
})

Deno.test('providers without a plan are left out', () => {
  equal(
    usageCards([
      provider('openai', 'responses'),
      provider('deepseek', 'anthropic'),
    ], now),
    [],
  )
})

Deno.test('every observed window keeps its figure and reset time', () => {
  const [card] = usageCards([
    provider('codex', 'codex', {
      plan: 'pro',
      observedAt: seconds('2026-09-27T11:55:00Z'),
      windows: [
        {
          name: 'five_hour',
          usedPercent: 0,
          resetsAt: seconds('2026-09-27T14:00:00Z'),
        },
        {
          name: 'seven_day',
          usedPercent: 71.6,
          resetsAt: seconds('2026-09-30T00:00:00Z'),
        },
      ],
    }),
  ], now)
  equal(card, {
    provider: 'codex',
    kind: 'observed',
    plan: 'pro',
    observedAt: new Date('2026-09-27T11:55:00Z'),
    windows: [
      {
        name: 'five hour',
        meter: { kind: 'used', percent: 0 },
        resetsAt: new Date('2026-09-27T14:00:00Z'),
      },
      {
        name: 'seven day',
        meter: { kind: 'used', percent: 71.6 },
        resetsAt: new Date('2026-09-30T00:00:00Z'),
      },
    ],
  })
})

Deno.test('a window without a figure is unreported, not 0%', () => {
  const [card] = usageCards([
    provider('claude', 'claude', {
      observedAt: seconds('2026-09-27T11:59:00Z'),
      windows: [{ name: 'seven_day_opus' }],
    }),
  ], now)
  equal(card.kind === 'unobserved' ? null : card.windows[0], {
    name: 'seven day opus',
    meter: { kind: 'unreported' },
    resetsAt: null,
  })
})

Deno.test('a window whose reset has passed no longer claims its old figure', () => {
  const [card] = usageCards([
    provider('codex', 'codex', {
      observedAt: seconds('2026-09-27T11:50:00Z'),
      windows: [{
        name: 'five_hour',
        usedPercent: 98,
        resetsAt: seconds('2026-09-27T11:58:00Z'),
      }],
    }),
  ], now)
  equal(card.kind === 'unobserved' ? null : card.windows[0].meter, {
    kind: 'reset',
  })
})

Deno.test('a reading older than two missed refreshes is stale', () => {
  const at = (iso: string) =>
    usageCards([
      provider('claude', 'claude', {
        observedAt: seconds(iso),
        windows: [{ name: 'five_hour', usedPercent: 12 }],
      }),
    ], now)[0].kind
  equal(at('2026-09-27T11:31:00Z'), 'observed')
  equal(at('2026-09-27T11:29:00Z'), 'stale')
})

Deno.test('the bar warms at 60% and turns rose at 90%', () => {
  equal([0, 59.9, 60, 89.9, 90, 100].map(usageTone), [
    'mint',
    'mint',
    'amber',
    'amber',
    'rose',
    'rose',
  ])
})
