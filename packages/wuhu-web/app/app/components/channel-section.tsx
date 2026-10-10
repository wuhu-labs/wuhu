import { SidebarNote, SidebarRow, SidebarSection } from '@wuhu/ui'
import type { ChannelSummary } from '~/lib/channels'
import { initialsFrom } from '~/lib/directory'
import { withGroup } from '~/lib/links'

export function ChannelSection({ channels, group, here, onNavigate }: {
  channels: ChannelSummary[] | null
  group: string
  here: string
  onNavigate: (href: string) => void
}) {
  return (
    <SidebarSection title='Channels'>
      {channels === null && <SidebarNote>Loading…</SidebarNote>}
      {channels?.map((channel) => {
        const href = withGroup(`/_/conversations/${channel.id}`, group)
        return (
          <SidebarRow
            key={channel.id}
            label={channel.title}
            href={href}
            active={here === href}
            unread={channel.unread}
            mark={
              <span className='wui-mark-glyph' aria-hidden='true'>
                {initialsFrom(channel.title)}
              </span>
            }
            onClick={() => onNavigate(href)}
          />
        )
      })}
    </SidebarSection>
  )
}
