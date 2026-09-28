import type { ReactNode } from 'react'
import {
  AppShell,
  ComposerZone,
  Crumbs,
  Icon,
  PrimaryAction,
  SearchField,
  Sidebar,
  SidebarActions,
  SidebarFooter,
  SidebarHeader,
  SidebarRow,
  SidebarScroll,
  SidebarSection,
  ThreadHead,
  ThreadMessage,
  Topbar,
  TopbarActions,
} from '@wuhu/ui'

export type LabPage = 'study' | 'tokens' | 'doc' | 'blocks' | 'peek'

export function LabChrome(
  { page, leaf, path = ['design'], navigate, composer, children }: {
    page: LabPage
    leaf: string
    path?: string[]
    navigate: (to: string) => void
    composer?: ReactNode
    children: ReactNode
  },
) {
  return (
    <AppShell
      canvas={page === 'doc' || page === 'blocks' || page === 'peek'
        ? 'quiet'
        : 'atmospheric'}
      sidebar={
        <Sidebar>
          <SidebarHeader brand='wuhu' />
          <SidebarActions>
            <PrimaryAction label='New session' kbd='⌘N' />
            <SearchField label='Search this space' kbd='⌘K' />
          </SidebarActions>
          <SidebarScroll>
            <SidebarSection title='Sessions' count='5 active'>
              <SidebarRow
                mark={<span className='wui-mark-glyph'>WR</span>}
                label='Wuhu redesign'
                meta='3'
                active={false}
                expanded
                onToggle={() => {}}
              />
              <SidebarRow
                mark={<span className='wui-mark-glyph'>CD</span>}
                label='Chrome direction'
                depth={1}
                status={{ tone: 'amber', label: 'working' }}
              />
              <SidebarRow
                mark={<span className='wui-mark-glyph'>ST</span>}
                label='Session tree'
                depth={1}
                unread
              />
              <SidebarRow
                mark={
                  <span className='wui-mark-glyph'>
                    <Icon name='hammer' />
                  </span>
                }
                label='Artifact depth'
                depth={2}
                status={{ tone: 'rose', label: 'errored' }}
              />
              <SidebarRow
                mark={<span className='wui-mark-glyph'>SV</span>}
                label='Ship v0'
                unread
              />
              <SidebarRow icon='archive' label='Archived' meta='12' quiet />
            </SidebarSection>
            <SidebarSection title='Space'>
              <SidebarRow
                icon='home'
                label='Home'
                href='/'
                active={page === 'study'}
                onClick={() => navigate('/')}
              />
              <SidebarRow icon='folder' label='Issues' meta='55' />
              <SidebarRow
                icon='note'
                label='Notes'
                href='/doc'
                active={page === 'doc'}
                onClick={() => navigate('/doc')}
              />
              <SidebarRow icon='plan' label='Plans' />
              <SidebarRow
                icon='note'
                label='Peek'
                href='/peek'
                active={page === 'peek'}
                onClick={() => navigate('/peek')}
              />
              <SidebarRow
                icon='note'
                label='Blocks'
                href='/blocks'
                active={page === 'blocks'}
                onClick={() => navigate('/blocks')}
              />
              <SidebarRow
                icon='tokens'
                label='Tokens'
                href='/tokens'
                active={page === 'tokens'}
                onClick={() => navigate('/tokens')}
              />
            </SidebarSection>
          </SidebarScroll>
          <SidebarFooter
            initials='AM'
            name='Alex Morgan'
            detail='space.example.com · connected'
          />
        </Sidebar>
      }
      topbar={
        <Topbar>
          <Crumbs path={path.map((label) => ({ label }))} leaf={leaf} />
          <TopbarActions
            actions={[{ label: 'Rename', icon: 'note', onSelect: () => {} }]}
            menu={[{ label: 'Share', icon: 'share', onSelect: () => {} }]}
          />
        </Topbar>
      }
      composer={composer ?? (
        <ComposerZone
          session={{ label: 'Wuhu redesign', dot: 'mint' }}
          thread={
            <>
              <ThreadHead
                title='Wuhu redesign · with 3 agents'
                meta='2 recent'
              />
              <ThreadMessage avatar='A1' author='Chrome direction'>
                Study is live. Translucency stays at the edges — the artifact
                scrolls beneath the bar and composer, so the material reads as
                depth instead of decoration.
              </ThreadMessage>
              <ThreadMessage avatar='AM' author='Alex Morgan' you>
                Good. Keep content surfaces opaque; blur only where layers
                actually meet.
              </ThreadMessage>
            </>
          }
        >
          <input
            aria-label='Message this session'
            placeholder={page === 'tokens'
              ? 'Ask Wuhu about these tokens…'
              : 'Ask Wuhu about this artifact…'}
          />
          <button type='button' className='wui-send-button' aria-label='Send'>
            <Icon name='send' />
          </button>
        </ComposerZone>
      )}
    >
      {children}
    </AppShell>
  )
}
