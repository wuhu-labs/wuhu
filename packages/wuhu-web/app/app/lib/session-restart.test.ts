import type { ProviderDescriptor } from './contract.gen.ts'
import { adoptSpec, restartInput } from './session-restart.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const sol = {
  id: 'gpt-6-sol',
  effortLevels: ['low', 'medium', 'high'],
  defaultEffort: 'medium',
}
const flash = {
  id: 'deepseek-flash',
  effortLevels: ['low', 'medium', 'max'],
  defaultEffort: 'medium',
}
const providers: ProviderDescriptor[] = [
  { id: 'codex', dialect: 'codex', models: [sol] },
  { id: 'deepseek', dialect: 'anthropic', models: [flash] },
]

Deno.test('Start over opens on the live spec, and an untouched confirm sends no spec', () => {
  const live = { provider: 'deepseek', model: 'deepseek-flash', effort: 'max' }
  const adopted = adoptSpec(providers, live)
  equal(adopted, {
    choice: { provider: 'deepseek', model: flash, effort: 'max' },
    unmatched: { model: null, effort: null },
  })
  equal(restartInput(adopted.choice, live, '', 'UTC'), { timezone: 'UTC' })
})

Deno.test('a changed pick is sent in full', () => {
  const live = { provider: 'deepseek', model: 'deepseek-flash', effort: 'max' }
  equal(
    restartInput(
      { provider: 'deepseek', model: flash, effort: 'low' },
      live,
      '',
      'UTC',
    ),
    {
      provider: 'deepseek',
      model: 'deepseek-flash',
      effort: 'low',
      timezone: 'UTC',
    },
  )
  equal(
    restartInput(
      { provider: 'codex', model: sol, effort: 'medium' },
      live,
      '',
      'UTC',
    ),
    {
      provider: 'codex',
      model: 'gpt-6-sol',
      effort: 'medium',
      timezone: 'UTC',
    },
  )
})

Deno.test('a model no longer offered stays unpicked and blocks Start over until one is picked', () => {
  const live = {
    provider: 'deepseek',
    model: 'deepseek-v4-flash',
    effort: 'high',
  }
  const adopted = adoptSpec(providers, live)
  equal(adopted, {
    choice: { provider: 'deepseek', model: null, effort: null },
    unmatched: { model: 'deepseek-v4-flash', effort: null },
  })
  equal(restartInput(adopted.choice, live, '', 'UTC'), null)
  equal(
    restartInput(
      { provider: 'deepseek', model: flash, effort: 'medium' },
      live,
      '',
      'UTC',
    ),
    {
      provider: 'deepseek',
      model: 'deepseek-flash',
      effort: 'medium',
      timezone: 'UTC',
    },
  )
})

Deno.test('a provider that left the catalog is kept, never swapped for the first one', () => {
  const live = { provider: 'retired', model: 'old-model', effort: 'low' }
  const adopted = adoptSpec(providers, live)
  equal(adopted, {
    choice: { provider: 'retired', model: null, effort: null },
    unmatched: { model: 'old-model', effort: null },
  })
  equal(restartInput(adopted.choice, live, '', 'UTC'), null)
})

Deno.test('an effort the model no longer offers stays unpicked and is not sent', () => {
  const live = { provider: 'codex', model: 'gpt-6-sol', effort: 'xhigh' }
  const adopted = adoptSpec(providers, live)
  equal(adopted, {
    choice: { provider: 'codex', model: sol, effort: null },
    unmatched: { model: null, effort: 'xhigh' },
  })
  equal(restartInput(adopted.choice, live, '', 'UTC'), {
    provider: 'codex',
    model: 'gpt-6-sol',
    timezone: 'UTC',
  })
})

Deno.test('the opening message rides along only when there is one', () => {
  const live = { provider: 'codex', model: 'gpt-6-sol', effort: 'high' }
  const choice = { provider: 'codex', model: sol, effort: 'high' }
  equal(restartInput(choice, live, '  pick up the audit  ', 'Asia/Shanghai'), {
    message: 'pick up the audit',
    timezone: 'Asia/Shanghai',
  })
  equal(restartInput(choice, live, '   ', 'UTC'), { timezone: 'UTC' })
})
