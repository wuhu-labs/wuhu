import { viewOpening } from './view-opening.ts'

Deno.test('unsupported view kinds show their definition instead of a provider', () => {
  const content = '{"view":"gantt"}'
  const opening = viewOpening(content)
  const expected = {
    state: 'text',
    content,
    notice: 'Unsupported view kind: gantt — showing the raw view doc.',
  }
  if (JSON.stringify(opening) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(opening)}`,
    )
  }
})
