import { spaceScope } from './space-feeds.tsx'

Deno.test('account and space key the roster and file-revision provider', () => {
  const a = spaceScope({ principal: 'first', spaceId: 'space-a' })
  const b = spaceScope({ principal: 'first', spaceId: 'space-b' })
  const c = spaceScope({ principal: 'second', spaceId: 'space-a' })
  if (a === b || a === c || b === c) {
    throw new Error('scope leaked across account or space')
  }
  if (spaceScope({ spaceId: 'space-a' }) !== null) {
    throw new Error('account must be known before keying')
  }
})
