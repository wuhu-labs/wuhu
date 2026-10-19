import { sessionTone } from '../components/space-sidebar.tsx'
import { renderToStaticMarkup } from 'react-dom/server'
import { SidebarRow } from '@wuhu/ui'
import { SessionRow } from '../components/session-row.tsx'

Deno.test('sidebar count capsule is absent for missing and nonpositive counts', () => {
  const render = (badge?: number | null) =>
    renderToStaticMarkup(<SidebarRow label='Desk' href='/desk' badge={badge} />)
  const plain = render()
  for (const badge of [null, 0, -1]) {
    if (render(badge) !== plain) {
      throw new Error('A nonpositive badge changed the row')
    }
  }
  for (const badge of [3, 125]) {
    if (
      !render(badge).includes(`class="wui-pill wui-row-badge">${badge}</span>`)
    ) throw new Error('Missing count capsule')
  }
})

Deno.test('custom session rows retain the trailing status dot followed by their count', () => {
  const html = renderToStaticMarkup(
    <SessionRow
      session={{
        id: 'designer',
        group: 'shared',
        title: 'Designer',
        hold: '',
        work: 'has_work',
        runState: 'inference',
        lifecycle: 'active',
        kind: 'agent',
        parent: null,
        unread: false,
      }}
      label='Desk'
      badge={3}
      depth={0}
      active={false}
      onNavigate={() => {}}
    />,
  )
  const dot = html.indexOf('wui-row-status')
  const badge = html.indexOf('class="wui-pill wui-row-badge">3</span>')
  if (dot === -1 || badge < dot || !html.includes('aria-label="working"')) {
    throw new Error(
      'The session status and count must both be present in dot-then-badge order',
    )
  }
})

Deno.test('session tone gives errors precedence over unknown runs and keeps unknown work idle', () => {
  const session = {
    lifecycle: 'live',
    hold: 'normal',
    work: 'errored',
    runState: 'unknown' as const,
  }
  if (sessionTone(session) !== 'rose') {
    throw new Error('Errored work must remain visible')
  }
  if (
    sessionTone({ ...session, work: 'unknown', runState: 'tool' }) !== 'idle'
  ) throw new Error('Unknown work must not look active')
})
