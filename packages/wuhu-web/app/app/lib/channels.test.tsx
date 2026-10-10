import { renderToStaticMarkup } from 'react-dom/server'
import { ChannelSection } from '../components/channel-section.tsx'
import { channelRows } from './channels.ts'
import { rowTarget } from './sidebars.ts'

Deno.test('Everything Channels lists titled and fallback channels with viewer unread and selected destination', () => {
  const channels = channelRows({
    columns: ['id', 'title', 'unread'],
    rows: [
      ['team', 'Team', 1],
      ['untitled', 'alice, bob', 0],
    ],
  })
  const html = renderToStaticMarkup(
    <ChannelSection
      channels={channels}
      group='shared'
      here='/_/conversations/team'
      onNavigate={() => {}}
    />,
  )
  for (
    const text of [
      'Channels',
      'Team',
      'alice, bob',
      '/_/conversations/team',
      'wui-row wui-active',
      'aria-label="unread"',
    ]
  ) {
    if (!html.includes(text)) throw new Error(`missing ${text}: ${html}`)
  }
  if (channels[1].unread) throw new Error('read channel must not have a dot')
})

Deno.test('custom sidebar channel row opens and selects the same conversation href', () => {
  const target = rowTarget('/_/conversations/team', null, 'shared')
  if (
    target?.kind !== 'conversation' || target.href !== '/_/conversations/team'
  ) throw new Error(JSON.stringify(target))
})
