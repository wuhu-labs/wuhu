import {
  agentTemplates,
  applyTemplate,
  defaultEffortOf,
  defaultModelOf,
  draftReady,
  emptyDraft,
  modelOf,
  selectableProviders,
  sessionCreateInput,
  type SessionDraft,
} from './session-create.ts'
import type { ProviderDescriptor, ProviderModel } from './contract.gen.ts'

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

const opus: ProviderModel = {
  id: 'claude-opus-5-5[1m]',
  effortLevels: ['high', 'max'],
  defaultEffort: 'high',
}

const plain: ProviderModel = {
  id: 'plain',
  effortLevels: [],
}

const anthropic: ProviderDescriptor = {
  id: 'anthropic',
  dialect: 'anthropic',
  models: [sonnet, plain],
}

const claude: ProviderDescriptor = {
  id: 'claude',
  dialect: 'claude',
  models: [opus],
  usage: {
    windows: [{ name: 'five_hour', usedPercent: 33, resetsAt: 1790184600 }],
    observedAt: 1790170000,
  },
}

const empty: ProviderDescriptor = {
  id: 'mimo',
  dialect: 'responses',
  models: [],
}

function draft(patch: Partial<SessionDraft>): SessionDraft {
  return { ...emptyDraft, ...patch }
}

Deno.test('a draft makes an agent with its provider, the model id, and the effort', () => {
  const result = sessionCreateInput(draft({
    title: '  build the thing  ',
    provider: 'anthropic',
    model: sonnet,
    effort: 'high',
  }))
  assertEquals(result, {
    input: {
      title: 'build the thing',
      kind: 'agent',
      provider: 'anthropic',
      model: 'claude-sonnet-5',
      effort: 'high',
    },
  })
})

Deno.test('an effortless model sends no effort, and a template rides along', () => {
  const result = sessionCreateInput(draft({
    title: 't',
    provider: 'anthropic',
    model: plain,
    effort: null,
    template: 'night',
  }))
  assertEquals(result, {
    input: {
      title: 't',
      kind: 'agent',
      provider: 'anthropic',
      model: 'plain',
      template: 'night',
    },
  })
})

Deno.test('a draft is not ready without a title or a model', () => {
  const ready = draft({
    title: 'x',
    provider: 'claude',
    model: opus,
  })
  assertEquals(draftReady(ready), true)
  assertEquals(draftReady({ ...ready, title: '   ' }), false)
  assertEquals(draftReady({ ...ready, model: null }), false)
  assertEquals(sessionCreateInput({ ...ready, model: null }), {
    error: 'pick a model',
  })
})

Deno.test('only providers with models are offered', () => {
  assertEquals(
    selectableProviders([anthropic, empty, claude]).map((p) => p.id),
    [
      'anthropic',
      'claude',
    ],
  )
})

Deno.test('model and effort defaults follow the provider and model declarations', () => {
  assertEquals(defaultModelOf(anthropic)?.id, 'claude-sonnet-5')
  assertEquals(
    modelOf(claude, 'claude-opus-5-5[1m]')?.id,
    'claude-opus-5-5[1m]',
  )
  assertEquals(modelOf(claude, 'nope'), null)
  assertEquals(defaultEffortOf(sonnet), 'medium')
  assertEquals(defaultEffortOf(plain), null)
  assertEquals(defaultEffortOf({ ...sonnet, defaultEffort: 'ultra' }), null)
})

Deno.test('a template picks its provider, model, and an offered effort', () => {
  const picked = applyTemplate(
    draft({ title: 'x', provider: 'anthropic', model: sonnet }),
    {
      name: 'night',
      kind: 'task',
      provider: 'claude',
      model: 'claude-opus-5-5[1m]',
      effort: 'max',
    },
    [anthropic, claude],
  )
  assertEquals(picked.provider, 'claude')
  assertEquals(picked.model?.id, 'claude-opus-5-5[1m]')
  assertEquals(picked.effort, 'max')
  assertEquals(picked.template, 'night')

  const unoffered = applyTemplate(
    draft({}),
    { name: 'odd', provider: 'claude', effort: 'low' },
    [claude],
  )
  assertEquals(unoffered.model?.id, 'claude-opus-5-5[1m]')
  // An effort the model does not offer falls back to its default.
  assertEquals(unoffered.effort, 'high')

  const unknown = applyTemplate(
    draft({ provider: 'anthropic', model: sonnet }),
    {
      name: 'gone',
      provider: 'retired',
    },
    [anthropic],
  )
  // An unknown provider leaves the pick alone.
  assertEquals(unknown.provider, 'anthropic')
  assertEquals(unknown.template, 'gone')

  assertEquals(
    applyTemplate(draft({ template: 'night' }), null, [claude]).template,
    null,
  )
})

Deno.test('a person is offered no task templates', () => {
  assertEquals(
    agentTemplates([
      { name: 'coder', kind: 'task' },
      { name: 'lead', kind: 'agent' },
      { name: 'plain' },
    ]).map((t) => t.name),
    ['lead', 'plain'],
  )
})
