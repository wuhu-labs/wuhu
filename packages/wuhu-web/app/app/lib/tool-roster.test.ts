import type { ToolRosterDescriptor } from './contract.gen.ts'
import { matchingTools, rosterSummary, rosterTools } from './tool-roster.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const tool = (name: string, description = `${name} things`) => ({
  name,
  description,
  parameters: { type: 'object' },
})

const rosters: ToolRosterDescriptor[] = [
  {
    executor: 'kernel',
    tools: [tool('read'), tool('compact', 'Fold the transcript'), tool('bash')],
  },
  { executor: 'claude-code', tools: [tool('read'), tool('bash')] },
]

Deno.test('each executor reads its own roster', () => {
  equal(rosterTools(rosters, 'kernel').map((t) => t.name), [
    'read',
    'compact',
    'bash',
  ])
  equal(rosterTools(rosters, 'claude-code').map((t) => t.name), [
    'read',
    'bash',
  ])
  equal(rosterTools([], 'kernel'), [])
})

Deno.test('the filter matches name or description, case-blind', () => {
  const kernel = rosterTools(rosters, 'kernel')
  equal(matchingTools(kernel, '  ').length, 3)
  equal(matchingTools(kernel, 'BASH').map((t) => t.name), ['bash'])
  equal(matchingTools(kernel, 'transcript').map((t) => t.name), ['compact'])
})

Deno.test('the summary names the tools only one executor gets', () => {
  equal(rosterSummary(rosters, 'kernel'), '3 tools; kernel-only: compact')
  equal(rosterSummary(rosters, 'claude-code'), '2 tools')
  equal(rosterSummary([rosters[1]], 'claude-code'), '2 tools')
  equal(
    rosterSummary([{ executor: 'kernel', tools: [tool('read')] }], 'kernel'),
    '1 tool',
  )
})
