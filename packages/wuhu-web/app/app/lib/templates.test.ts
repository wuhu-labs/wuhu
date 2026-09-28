import {
  emptyTemplateDraft,
  templateBrief,
  templateDirectory,
  type TemplateDraft,
  templateLine,
  templateManifest,
  templateNameError,
  templateReady,
} from './templates.ts'
import type { ProviderModel } from './contract.gen.ts'

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const sonnet: ProviderModel = {
  id: 'claude-sonnet-5',
  effortLevels: ['low', 'medium', 'high'],
  defaultEffort: 'medium',
}

function draft(patch: Partial<TemplateDraft>): TemplateDraft {
  return { ...emptyTemplateDraft, ...patch }
}

Deno.test('the name grammar is lowercase letters, digits and dashes', () => {
  assertEquals(templateNameError('night-shift'), null)
  assertEquals(templateNameError('a1'), null)
  assertEquals(templateNameError(''), 'Name the template.')
  for (const name of ['Night', 'night shift', 'night_shift', 'a/b', 'ä']) {
    assertEquals(
      templateNameError(name),
      'A template name is lowercase letters, digits and dashes.',
    )
  }
})

Deno.test('a template is ready once it has a legal name, a kind and a provider', () => {
  assertEquals(templateReady(emptyTemplateDraft), false)
  assertEquals(templateReady(draft({ name: 'x', kind: 'task' })), false)
  assertEquals(
    templateReady(draft({ name: 'x', kind: 'task', provider: 'anthropic' })),
    true,
  )
  assertEquals(
    templateReady(draft({ name: 'X', kind: 'task', provider: 'anthropic' })),
    false,
  )
})

Deno.test('the manifest carries only the keys the grammar accepts', () => {
  const manifest = templateManifest(draft({
    name: 'night-shift',
    kind: 'task',
    provider: 'anthropic',
    model: sonnet,
    effort: 'high',
    description: '  overnight grinding  ',
    brief: 'ignored by the manifest',
  }))
  assertEquals(JSON.parse(manifest), {
    kind: 'task',
    description: 'overnight grinding',
    provider: 'anthropic',
    model: 'claude-sonnet-5',
    effort: 'high',
  })
  assertEquals(manifest.endsWith('\n'), true)
})

Deno.test('empty manifest fields are omitted, not sent as null', () => {
  assertEquals(
    JSON.parse(templateManifest(draft({
      name: 'plain',
      kind: 'agent',
      provider: 'claude',
      model: sonnet,
      effort: null,
    }))),
    { kind: 'agent', provider: 'claude', model: 'claude-sonnet-5' },
  )
})

Deno.test('an empty brief becomes a heading so the home has an AGENTS.md', () => {
  assertEquals(templateBrief(draft({ name: 'night-shift' })), '# night-shift\n')
  assertEquals(
    templateBrief(draft({ name: 'x', brief: '  Read the plan.  ' })),
    'Read the plan.\n',
  )
})

Deno.test('a template lives in its own directory and reads as one mono line', () => {
  assertEquals(templateDirectory('night-shift'), '/templates/night-shift')
  assertEquals(
    templateLine({ name: 'a', provider: 'claude', model: 'x', effort: 'high' }),
    'claude · x · high',
  )
  assertEquals(templateLine({ name: 'a', provider: 'claude' }), 'claude')
  assertEquals(
    templateLine({ name: 'a', provider: 'claude', model: null, effort: 'low' }),
    'claude · low',
  )
})
